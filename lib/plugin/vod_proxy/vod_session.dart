import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/pl_player/utils/video_stall_monitor.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_pool.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_range.dart';

class VodSession {
  VodSession({
    required this.id,
    required this.kind,
    required List<String> candidates,
    required this.chunkSize,
    required this.windowBytes,
    required this.workers,
  }) : pool = VodHostPool(candidates);

  final String id;
  final String kind;
  final VodHostPool pool;
  final int chunkSize;
  final int windowBytes;
  final int workers;

  final HttpClient _client = HttpClient()
    ..userAgent = BrowserUa.pc
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 20)
    ..autoUncompress = false;

  final Map<int, Uint8List> _chunks = {};
  final Map<int, Future<Uint8List>> _inflight = {};
  int? fileSize;
  int _cursor = 0;
  int _bytesServed = 0;
  int _bytesFetched = 0;
  final DateTime startedAt = DateTime.now();
  bool _closed = false;
  Timer? _statsTimer;

  void startStats() {
    _statsTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_closed) return;
      VideoStallLog.proxy(
        'stats id=$id kind=$kind served=${_fmtBytes(_bytesServed)} '
        'fetched=${_fmtBytes(_bytesFetched)} ${_throughput()} '
        'ahead=${_fmtBytes(_aheadBytes)} cursor=$_cursor '
        'size=${fileSize ?? -1} hosts=${pool.describe()}',
      );
    });
  }

  int get _aheadBytes {
    if (fileSize == null) return 0;
    var n = 0;
    for (final e in _chunks.entries) {
      if (e.key * chunkSize >= _cursor) n += e.value.length;
    }
    return n;
  }

  String _throughput() {
    final sec = DateTime.now().difference(startedAt).inMilliseconds / 1000;
    if (sec <= 0) return '0MB/s';
    return '${(_bytesFetched / sec / 1024 / 1024).toStringAsFixed(2)}MB/s';
  }

  static String _fmtBytes(int n) {
    if (n >= 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(n / 1024).toStringAsFixed(0)}KB';
  }

  Future<int> ensureSize() async {
    final known = fileSize;
    if (known != null && known > 0) return known;
    final range = const ByteRange(0, 1);
    final probe = await _fetchRange(range, urgent: true);
    fileSize ??= probe.total;
    _chunks[0] = probe.bytes.length >= chunkSize
        ? probe.bytes.sublist(0, 1)
        : probe.bytes;
    // Don't keep a 1-byte stub as chunk 0; refetch the real first chunk later.
    _chunks.remove(0);
    VideoStallLog.proxy(
      'size id=$id kind=$kind bytes=${fileSize ?? -1} '
      'hosts=${pool.hosts.map((h) => h.host).join(",")}',
    );
    if (pool.nearDeadline) {
      VideoStallLog.proxy(
        'deadline-soon id=$id deadline=${pool.deadlineSec}',
      );
    }
    return fileSize ?? 0;
  }

  Stream<List<int>> read(int start, int endExclusive) async* {
    if (_closed) return;
    _cursor = start;
    startStats();
    _evict();
    unawaited(_prefetch(start));
    var pos = start;
    while (!_closed && pos < endExclusive) {
      final idx = pos ~/ chunkSize;
      final chunk = await _chunk(idx, urgent: pos == start);
      if (_closed) return;
      final offset = pos - idx * chunkSize;
      if (offset >= chunk.length) {
        return;
      }
      final take = min(chunk.length - offset, endExclusive - pos);
      yield chunk.sublist(offset, offset + take);
      pos += take;
      _cursor = pos;
      _bytesServed += take;
      _evict();
      unawaited(_prefetch(pos));
    }
  }

  Future<void> _prefetch(int from) async {
    final size = fileSize;
    if (size == null || size <= 0) return;
    final until = min(from + windowBytes, size);
    final ranges = splitRanges(from, until, chunkSize);
    var launched = 0;
    for (final range in ranges) {
      if (_closed) return;
      final idx = range.start ~/ chunkSize;
      if (_chunks.containsKey(idx) || _inflight.containsKey(idx)) continue;
      if (_inflight.length >= workers) break;
      unawaited(_chunk(idx));
      launched++;
      if (launched >= workers) break;
    }
  }

  Future<Uint8List> _chunk(int idx, {bool urgent = false}) {
    final cached = _chunks[idx];
    if (cached != null) return Future.value(cached);
    return _inflight.putIfAbsent(idx, () async {
      final size = fileSize ?? await ensureSize();
      final start = idx * chunkSize;
      final end = min(start + chunkSize, size);
      final fetched = await _fetchRange(
        ByteRange(start, end),
        urgent: urgent,
      );
      fileSize ??= fetched.total;
      _chunks[idx] = fetched.bytes;
      _inflight.remove(idx);
      return fetched.bytes;
    });
  }

  Future<({Uint8List bytes, int total})> _fetchRange(
    ByteRange range, {
    required bool urgent,
  }) async {
    Object? lastError;
    String? lastHost;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_closed) {
        throw StateError('session closed');
      }
      final url = pool.pickUrl(avoidHost: lastHost);
      if (url == null) break;
      lastHost = Uri.tryParse(url)?.host;
      try {
        final result = urgent && attempt == 0
            ? await _hedgedGet(url, range)
            : await _get(url, range);
        _bytesFetched += result.bytes.length;
        if (result.bytes.length != range.length) {
          pool.recordFailure(url, reason: 'short-read');
          VideoStallLog.proxy(
            'retry id=$id range=$range from=$lastHost reason=short-read '
            'got=${result.bytes.length} want=${range.length}',
          );
          lastError = StateError('short read');
          continue;
        }
        return result;
      } on _Forbidden {
        pool.recordFailure(
          url,
          reason: '403',
          ban: const Duration(seconds: 45),
        );
        VideoStallLog.proxy(
          'retry id=$id range=$range from=$lastHost reason=403',
        );
        lastError = _Forbidden();
      } catch (e) {
        pool.recordFailure(url, reason: e.toString());
        VideoStallLog.proxy(
          'retry id=$id range=$range from=$lastHost reason=$e',
        );
        lastError = e;
      }
    }
    throw lastError ?? StateError('no host for $range');
  }

  Future<({Uint8List bytes, int total})> _hedgedGet(
    String url,
    ByteRange range,
  ) async {
    final primary = _get(url, range);
    final backupUrl = pool.pickUrl(avoidHost: Uri.tryParse(url)?.host);
    if (backupUrl == null) return primary;
    final backup = Future<({Uint8List bytes, int total})?>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        return await _get(backupUrl, range);
      } catch (_) {
        return null;
      }
    });
    final first = await Future.any([
      primary.then<(bool, ({Uint8List bytes, int total})?)>((v) => (true, v)),
      backup.then<(bool, ({Uint8List bytes, int total})?)>((v) => (false, v)),
    ]);
    if (first.$2 != null) return first.$2!;
    return primary;
  }

  Future<({Uint8List bytes, int total})> _get(
    String url,
    ByteRange range,
  ) async {
    final sw = Stopwatch()..start();
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.refererHeader, HttpString.baseUrl);
    req.headers.set(HttpHeaders.userAgentHeader, BrowserUa.pc);
    req.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=${range.start}-${range.endInclusive}',
    );
    req.followRedirects = true;
    final resp = await req.close().timeout(const Duration(seconds: 10));
    if (resp.statusCode == 403) {
      await resp.drain<void>().catchError((_) {});
      throw _Forbidden();
    }
    final body = await consolidate(resp);
    if (resp.statusCode == 206) {
      final parsed = ContentRangeReply.parse(
        resp.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (parsed == null ||
          !parsed.matches(
            start: range.start,
            endInclusive: range.endInclusive,
          )) {
        throw StateError(
          'bad Content-Range ${resp.headers.value(HttpHeaders.contentRangeHeader)}',
        );
      }
      pool.recordSuccess(
        url,
        bytes: body.length,
        elapsedMs: sw.elapsedMilliseconds,
      );
      return (bytes: body, total: parsed.total);
    }
    if (resp.statusCode == 200 && body.length == range.length) {
      pool.recordSuccess(
        url,
        bytes: body.length,
        elapsedMs: sw.elapsedMilliseconds,
      );
      return (bytes: body, total: fileSize ?? range.endExclusive);
    }
    throw StateError('http ${resp.statusCode} len=${body.length}');
  }

  static Future<Uint8List> consolidate(HttpClientResponse resp) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(const Duration(seconds: 12))) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _evict() {
    if (_chunks.isEmpty) return;
    final keepFrom = (_cursor - chunkSize * 2).clamp(0, 1 << 30);
    final keepTo = _cursor + windowBytes;
    _chunks.removeWhere((idx, _) {
      final start = idx * chunkSize;
      return start + chunkSize < keepFrom || start > keepTo;
    });
  }

  bool preferNextHost() {
    final next = pool.preferNext();
    if (next == null) return false;
    VideoStallLog.proxy('blacklist-rotate id=$id next=$next');
    return true;
  }

  void close() {
    _closed = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    _chunks.clear();
    _inflight.clear();
    _client.close(force: true);
  }
}

class _Forbidden implements Exception {}
