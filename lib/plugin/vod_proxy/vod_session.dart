import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
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
      VodProxyLog.log(
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

  /// Probe the original host for Content-Length / Content-Range total.
  /// Must finish quickly: mpv waits on the first proxy response.
  Future<int> ensureSize({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final known = fileSize;
    if (known != null && known > 0) return known;
    final probeEnd = chunkSize < 4096 ? chunkSize : 4096;
    final probe = await _fetchRange(
      ByteRange(0, probeEnd),
      urgent: true,
    ).timeout(timeout);
    fileSize ??= probe.total;
    final size = fileSize ?? 0;
    if (probe.bytes.isNotEmpty &&
        probe.bytes.length >= (size > 0 ? min(probeEnd, size) : probeEnd)) {
      // Not a full chunk — drop so _chunk(0) refetches the real slice.
    }
    VodProxyLog.log(
      'size id=$id kind=$kind bytes=$size '
      'hosts=${pool.hosts.map((h) => h.host).join(",")}',
    );
    if (pool.nearDeadline) {
      VodProxyLog.log('deadline-soon id=$id deadline=${pool.deadlineSec}');
    }
    return size;
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
      final Uint8List chunk;
      try {
        chunk = await _chunk(idx, urgent: pos == start);
      } on _SessionClosed {
        return;
      }
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
      unawaited(_chunkQuiet(idx));
      launched++;
      if (launched >= workers) break;
    }
  }

  Future<void> _chunkQuiet(int idx) async {
    try {
      await _chunk(idx);
    } on _SessionClosed {
      // Player moved on; in-flight Range work is expected to stop.
    }
  }

  Future<Uint8List> _chunk(int idx, {bool urgent = false}) {
    final cached = _chunks[idx];
    if (cached != null) return Future.value(cached);
    return _inflight.putIfAbsent(idx, () async {
      try {
        if (_closed) throw const _SessionClosed();
        final size = fileSize ?? await ensureSize();
        if (_closed) throw const _SessionClosed();
        final start = idx * chunkSize;
        final end = min(start + chunkSize, size);
        final fetched = await _fetchRange(
          ByteRange(start, end),
          urgent: urgent,
        );
        fileSize ??= fetched.total;
        _chunks[idx] = fetched.bytes;
        return fetched.bytes;
      } finally {
        _inflight.remove(idx);
      }
    });
  }

  Future<({Uint8List bytes, int total})> _fetchRange(
    ByteRange range, {
    required bool urgent,
  }) async {
    Object? lastError;
    String? lastHost;
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_closed) throw const _SessionClosed();
      final url = pool.pickUrl(avoidHost: lastHost);
      if (url == null) break;
      lastHost = Uri.tryParse(url)?.host;
      try {
        final result = await _get(url, range).timeout(
          const Duration(seconds: 6),
        );
        _bytesFetched += result.bytes.length;
        if (result.bytes.length != range.length) {
          pool.recordFailure(url, reason: 'short-read');
          VodProxyLog.log(
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
        VodProxyLog.log(
          'retry id=$id range=$range from=$lastHost reason=403',
        );
        lastError = _Forbidden();
      } on _SessionClosed {
        rethrow;
      } catch (e) {
        if (_closed) throw const _SessionClosed();
        pool.recordFailure(url, reason: e.toString());
        VodProxyLog.log(
          'retry id=$id range=$range from=$lastHost reason=$e',
        );
        lastError = e;
      }
    }
    throw lastError ?? StateError('no host for $range');
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
      if (parsed == null) {
        throw StateError(
          'bad Content-Range ${resp.headers.value(HttpHeaders.contentRangeHeader)}',
        );
      }
      fileSize ??= parsed.total;
      final slice = _sliceCovered(body, parsed, range);
      pool.recordSuccess(
        url,
        bytes: slice.length,
        elapsedMs: sw.elapsedMilliseconds,
      );
      return (bytes: slice, total: parsed.total);
    }
    if (resp.statusCode == 200) {
      final cl = int.tryParse(
        resp.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (cl != null && cl > 0) fileSize ??= cl;
      if (body.length >= range.length && range.start == 0) {
        pool.recordSuccess(
          url,
          bytes: range.length,
          elapsedMs: sw.elapsedMilliseconds,
        );
        return (
          bytes: body.sublist(0, range.length),
          total: fileSize ?? cl ?? body.length,
        );
      }
    }
    throw StateError('http ${resp.statusCode} len=${body.length}');
  }

  static Uint8List _sliceCovered(
    Uint8List body,
    ContentRangeReply parsed,
    ByteRange range,
  ) {
    final recvStart = parsed.start;
    final offset = range.start - recvStart;
    if (offset < 0 || offset >= body.length) {
      throw StateError('Content-Range $parsed missed $range');
    }
    final end = min(offset + range.length, body.length);
    return Uint8List.sublistView(body, offset, end);
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
    VodProxyLog.log('blacklist-rotate id=$id next=$next');
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

class _SessionClosed implements Exception {
  const _SessionClosed();
}
