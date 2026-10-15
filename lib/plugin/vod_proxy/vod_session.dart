import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_pool.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_range.dart';

class VodServeAbort implements Exception {
  VodServeAbort(this.range, this.reason);

  final ByteRange range;
  final Object? reason;

  @override
  String toString() => 'VodServeAbort $range reason=$reason';
}

class VodSession {
  VodSession({
    required this.id,
    required this.kind,
    required List<String> candidates,
    required this.chunkSize,
    required this.windowBytes,
    required this.workers,
    this.attemptTimeout = const Duration(seconds: 6),
    this.fetchBudget = const Duration(seconds: 45),
  }) : pool = VodHostPool(candidates);

  final String id;
  final String kind;
  final VodHostPool pool;
  final int chunkSize;
  final int windowBytes;
  final int workers;
  final Duration attemptTimeout;
  final Duration fetchBudget;

  final HttpClient _client = HttpClient()
    ..userAgent = BrowserUa.pc
    ..connectionTimeout = const Duration(seconds: 8)
    ..idleTimeout = const Duration(seconds: 20)
    ..autoUncompress = false;

  final Map<int, Uint8List> _chunks = {};
  final Map<int, Future<Uint8List>> _inflight = {};
  final Set<int> _fetchedChunks = {};
  final Set<int> _servedChunks = {};
  int? fileSize;
  int _cursor = 0;
  int _bytesDelivered = 0;
  int _bytesNet = 0;
  int retries = 0;
  int firstTtfbMs = 0;
  final DateTime startedAt = DateTime.now();
  DateTime? lastServeAt;
  bool _closed = false;
  bool _probed = false;
  bool _endLogged = false;
  bool _pauseLogged = false;
  String? fallbackReason;
  Timer? _statsTimer;
  int _readEpoch = 0;
  int _activeReads = 0;

  bool get isClosed => _closed;

  int get uniqueServedBytes {
    var n = 0;
    for (final idx in _servedChunks) {
      n += _chunks[idx]?.length ?? _chunkLen(idx);
    }
    final size = fileSize;
    if (size != null && n > size) return size;
    return n;
  }

  int get uniqueFetchedBytes {
    var n = 0;
    for (final idx in _fetchedChunks) {
      n += _chunks[idx]?.length ?? _chunkLen(idx);
    }
    final size = fileSize;
    if (size != null && n > size) return size;
    return n;
  }

  int _chunkLen(int idx) {
    final size = fileSize;
    if (size == null) return chunkSize;
    final start = idx * chunkSize;
    return min(chunkSize, size - start).clamp(0, chunkSize);
  }

  void startStats() {
    _statsTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_closed) return;
      if (_activeReads == 0 &&
          lastServeAt != null &&
          DateTime.now().difference(lastServeAt!) >
              const Duration(seconds: 12)) {
        _statsTimer?.cancel();
        _statsTimer = null;
        return;
      }
      VodProxyLog.log(
        'stats id=$id kind=$kind served=${_fmtBytes(uniqueServedBytes)} '
        'fetched=${_fmtBytes(uniqueFetchedBytes)} net=${_fmtBytes(_bytesNet)} '
        '${_throughput()} ahead=${_fmtBytes(_aheadBytes)} cursor=$_cursor '
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
    return '${(uniqueFetchedBytes / sec / 1024 / 1024).toStringAsFixed(2)}MB/s';
  }

  static String _fmtBytes(int n) {
    if (n >= 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(n / 1024).toStringAsFixed(0)}KB';
  }

  Future<int> ensureSize({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final known = fileSize;
    if (known != null && known > 0) {
      if (!_probed) {
        unawaited(_probeHosts());
      }
      return known;
    }
    await _probeHosts().timeout(timeout, onTimeout: () {});
    if (fileSize != null && fileSize! > 0) return fileSize!;
    final probeEnd = chunkSize < 4096 ? chunkSize : 4096;
    final probe = await _fetchRange(
      ByteRange(0, probeEnd),
      urgent: true,
    ).timeout(timeout);
    fileSize ??= probe.total;
    final size = fileSize ?? 0;
    VodProxyLog.log(
      'size id=$id kind=$kind bytes=$size '
      'hosts=${pool.hosts.map((h) => h.host).join(",")}',
    );
    if (pool.nearDeadline) {
      VodProxyLog.log('deadline-soon id=$id deadline=${pool.deadlineSec}');
    }
    return size;
  }

  Future<void> _probeHosts() async {
    if (_probed || _closed) return;
    _probed = true;
    final targets = pool.hosts.take(8).toList();
    if (targets.isEmpty) return;
    const probeBytes = 128 * 1024;
    await Future.wait(
      targets.map((stat) async {
        if (_closed) return;
        try {
          final result = await _get(
            stat.url,
            ByteRange(0, probeBytes),
            probe: true,
          ).timeout(const Duration(seconds: 3));
          fileSize ??= result.total;
          VodProxyLog.log(
            'probe id=$id host=${stat.host} ttfb=${stat.avgTtfbMs.toStringAsFixed(0)}ms '
            'thru=${(stat.emaBps * 8 / 1e6).toStringAsFixed(2)}Mbps status=ok',
          );
        } catch (e) {
          pool.recordFailure(stat.url, reason: 'probe $e', probe: true);
          VodProxyLog.log(
            'probe id=$id host=${stat.host} status=fail reason=$e',
          );
        }
      }),
    );
    if (_closed) return;
    pool.markOverseasWinnerIfNeeded();
    final ranked = pool.topHosts(k: 6);
    VodProxyLog.log(
      'rank id=$id overseasWins=${pool.overseasWins} '
      'hosts=${ranked.map((h) => '${h.host}:${(h.emaBps * 8 / 1e6).toStringAsFixed(1)}').join(",")}',
    );
    VodProxyLog.log(
      'size id=$id kind=$kind bytes=${fileSize ?? -1} '
      'hosts=${pool.hosts.map((h) => h.host).join(",")}',
    );
  }

  Stream<List<int>> read(int start, int endExclusive) async* {
    if (_closed) return;
    final epoch = ++_readEpoch;
    _activeReads++;
    startStats();
    _cursor = start;
    _evict();
    unawaited(_prefetch(start));
    try {
      var pos = start;
      while (!_closed && epoch == _readEpoch && pos < endExclusive) {
        final idx = pos ~/ chunkSize;
        final expected = _chunkLen(idx);
        final Uint8List chunk;
        try {
          chunk = await _chunkUntil(
            idx,
            urgent: pos == start,
            epoch: epoch,
          );
        } on _SessionClosed {
          return;
        }
        if (_closed || epoch != _readEpoch) return;
        if (chunk.length != expected) {
          throw VodServeAbort(
            ByteRange(idx * chunkSize, idx * chunkSize + expected),
            'bad-length got=${chunk.length} want=$expected',
          );
        }
        final offset = pos - idx * chunkSize;
        if (offset < 0 || offset >= chunk.length) {
          throw VodServeAbort(
            ByteRange(pos, endExclusive),
            'bad-offset offset=$offset len=${chunk.length}',
          );
        }
        final take = min(chunk.length - offset, endExclusive - pos);
        if (take <= 0) {
          throw VodServeAbort(ByteRange(pos, endExclusive), 'empty-take');
        }
        yield chunk.sublist(offset, offset + take);
        pos += take;
        _cursor = pos;
        _bytesDelivered += take;
        _servedChunks.add(idx);
        lastServeAt = DateTime.now();
        _pauseLogged = false;
        _evict();
        unawaited(_prefetch(pos));
      }
    } finally {
      _activeReads = (_activeReads - 1).clamp(0, 1 << 20);
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
    } catch (e) {
      VodProxyLog.log('prefetch-fail id=$id idx=$idx $e');
    }
  }

  Future<Uint8List> _chunkUntil(
    int idx, {
    required bool urgent,
    required int epoch,
  }) async {
    final deadline = DateTime.now().add(fetchBudget);
    Object? lastError;
    while (!_closed && epoch == _readEpoch) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining.inMilliseconds <= 0) {
        final start = idx * chunkSize;
        throw VodServeAbort(
          ByteRange(start, start + _chunkLen(idx)),
          lastError ?? 'deadline ${fetchBudget.inSeconds}s',
        );
      }
      try {
        final chunk = await _chunk(idx, urgent: urgent);
        final expected = _chunkLen(idx);
        if (chunk.length == expected) return chunk;
        _chunks.remove(idx);
        lastError = 'bad-length got=${chunk.length} want=$expected';
        VodProxyLog.log(
          'retry id=$id range=${ByteRange(idx * chunkSize, idx * chunkSize + expected)} '
          'from=- reason=$lastError',
        );
      } on _SessionClosed {
        rethrow;
      } on VodServeAbort {
        rethrow;
      } catch (e) {
        lastError = e;
        VodProxyLog.log('read-retry id=$id idx=$idx reason=$e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    throw const _SessionClosed();
  }

  Future<Uint8List> _chunk(int idx, {bool urgent = false}) {
    final cached = _chunks[idx];
    final expected = _chunkLen(idx);
    if (cached != null) {
      if (cached.length == expected) return Future.value(cached);
      _chunks.remove(idx);
    }
    return _inflight.putIfAbsent(idx, () async {
      try {
        if (_closed) throw const _SessionClosed();
        final size = fileSize ?? await ensureSize();
        if (_closed) throw const _SessionClosed();
        final start = idx * chunkSize;
        final end = min(start + chunkSize, size);
        final want = end - start;
        final fetched = await _fetchRange(
          ByteRange(start, end),
          urgent: urgent,
        );
        if (fetched.bytes.length != want) {
          throw StateError(
            'chunk-len got=${fetched.bytes.length} want=$want',
          );
        }
        fileSize ??= fetched.total;
        _chunks[idx] = fetched.bytes;
        _fetchedChunks.add(idx);
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
    final deadline = DateTime.now().add(fetchBudget);
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      if (_closed) throw const _SessionClosed();
      attempt++;
      final remaining = deadline.difference(DateTime.now());
      if (remaining.inMilliseconds < 50) break;
      final allowBanned = attempt >= 4;
      String? url;
      if (attempt >= 8 && pool.allUrls.isNotEmpty) {
        url = pool.allUrls[(attempt - 1) % pool.allUrls.length];
      } else {
        url = pool.pickUrl(avoidHost: lastHost, allowBanned: allowBanned);
      }
      if (url == null || url.isEmpty) {
        url = pool.primaryUrl;
      }
      if (url.isEmpty) break;
      lastHost = Uri.tryParse(url)?.host;
      final perTry = remaining < attemptTimeout ? remaining : attemptTimeout;
      try {
        final result = await _get(url, range).timeout(perTry);
        if (result.bytes.length != range.length) {
          retries++;
          pool.recordFailure(url, reason: 'short-read');
          VodProxyLog.log(
            'retry id=$id range=$range from=$lastHost reason=short-read '
            'got=${result.bytes.length} want=${range.length}',
          );
          lastError = StateError('short-read');
          continue;
        }
        return result;
      } on _Forbidden {
        retries++;
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
        retries++;
        pool.recordFailure(url, reason: e.toString());
        VodProxyLog.log(
          'retry id=$id range=$range from=$lastHost reason=$e',
        );
        lastError = e;
      }
    }
    final why = lastError ?? 'deadline ${fetchBudget.inSeconds}s n=$attempt';
    VodProxyLog.log('abort id=$id range=$range reason=$why');
    throw VodServeAbort(range, why);
  }

  Future<({Uint8List bytes, int total})> _get(
    String url,
    ByteRange range, {
    bool probe = false,
  }) async {
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
    final ttfbMs = sw.elapsedMilliseconds;
    if (firstTtfbMs == 0) firstTtfbMs = ttfbMs;
    if (resp.statusCode == 403) {
      await resp.drain<void>().catchError((_) {});
      throw _Forbidden();
    }
    final body = await consolidate(resp);
    _bytesNet += body.length;
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
      if (slice.length != range.length) {
        if (probe &&
            range.start == 0 &&
            parsed.total > 0 &&
            slice.length == parsed.total) {
          // File shorter than the probe window — still a valid 206.
        } else {
          throw StateError(
            'short-read got=${slice.length} want=${range.length}',
          );
        }
      }
      pool.recordSuccess(
        url,
        bytes: slice.length,
        elapsedMs: sw.elapsedMilliseconds,
        ttfbMs: ttfbMs,
        probe: probe,
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
          ttfbMs: ttfbMs,
          probe: probe,
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

  void logSessionEnd({String reason = 'close'}) {
    final pausing = reason == 'pause' || reason == 'detach';
    if (_endLogged) return;
    if (pausing && _pauseLogged) return;
    if (pausing) {
      _pauseLogged = true;
    } else {
      _endLogged = true;
    }
    VodProxyLog.log(
      'session_end id=$id kind=$kind reason=$reason '
      'served=${_fmtBytes(uniqueServedBytes)} '
      'fetched=${_fmtBytes(uniqueFetchedBytes)} '
      'net=${_fmtBytes(_bytesNet)} delivered=${_fmtBytes(_bytesDelivered)} '
      'retries=$retries bans=${pool.banReasons.isEmpty ? 0 : pool.banReasons.join("|")} '
      'ttfb=${firstTtfbMs}ms firstFrame=${VodProxyLog.firstFrameMs ?? '-'}ms '
      'fallback=${fallbackReason ?? '-'} '
      'hosts=${pool.sessionHostSummary()}',
    );
  }

  void close({String reason = 'close'}) {
    if (_closed) return;
    _closed = true;
    _readEpoch++;
    _statsTimer?.cancel();
    _statsTimer = null;
    logSessionEnd(reason: reason);
    _chunks.clear();
    _inflight.clear();
    _client.close(force: true);
  }
}

class _Forbidden implements Exception {}

class _SessionClosed implements Exception {
  const _SessionClosed();
}
