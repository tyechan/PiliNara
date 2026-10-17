import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_health.dart';
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
    this.cursorWatchdog = const Duration(milliseconds: 2500),
    int? backBufferBytes,
  }) : pool = VodHostPool(candidates),
       backBufferBytes = backBufferBytes ?? defaultBackBuffer(windowBytes) {
    pool.onBan = (host) => _kickFetches(fromHost: host);
  }

  static const int minBackBufferBytes = 192 * 1024 * 1024;

  static int defaultBackBuffer(int windowBytes) =>
      windowBytes > minBackBufferBytes ? windowBytes : minBackBufferBytes;

  final String id;
  final String kind;
  final VodHostPool pool;
  final int chunkSize;
  final int windowBytes;
  final int workers;
  final Duration attemptTimeout;
  final Duration fetchBudget;
  final Duration cursorWatchdog;
  final int backBufferBytes;
  void Function()? onCursorStuck;

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
  int _highWater = 0;
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
  Completer<void> _wake = Completer<void>();
  int _kickEpoch = 0;
  String? _kickedHost;
  final Map<int, String> _inflightHost = {};
  bool _statsPaused = false;

  bool get isClosed => _closed;

  int get bytesNet => _bytesNet;

  bool get statsRunning => _statsTimer != null;

  bool get statsPaused => _statsPaused;

  int get activeReads => _activeReads;

  DateTime? lastClientAt;

  void noteClient() => lastClientAt = DateTime.now();

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
    if (_closed || _statsPaused) return;
    _statsTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_closed || _statsPaused) return;
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

  void pauseStats() {
    _statsPaused = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    if (_pauseLogged) return;
    _pauseLogged = true;
    VodProxyLog.log(
      'session_pause id=$id kind=$kind '
      'served=${_fmtBytes(uniqueServedBytes)} '
      'fetched=${_fmtBytes(uniqueFetchedBytes)} '
      'net=${_fmtBytes(_bytesNet)} delivered=${_fmtBytes(_bytesDelivered)} '
      'retries=$retries cursor=$_cursor size=${fileSize ?? -1}',
    );
  }

  void resumeStats() {
    _statsPaused = false;
    _pauseLogged = false;
    VodProxyLog.log(
      'session_resume id=$id kind=$kind '
      'served=${_fmtBytes(uniqueServedBytes)} '
      'fetched=${_fmtBytes(uniqueFetchedBytes)} '
      'net=${_fmtBytes(_bytesNet)} cursor=$_cursor size=${fileSize ?? -1}',
    );
    startStats();
  }

  void _wakeWaiters() {
    if (!_wake.isCompleted) _wake.complete();
    _wake = Completer<void>();
  }

  void _kickFetches({String? fromHost}) {
    if (fromHost != null) {
      _kickedHost = fromHost.toLowerCase();
      _kickEpoch++;
      VodProxyLog.log('requeue id=$id from=$fromHost');
    }
    _wakeWaiters();
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
          final thruMbps = stat.emaBps * 8 / 1e6;
          if (kind == 'video') {
            VodHostHealth.instance.noteVideoProbe(
              stat.host,
              ttfbMs: stat.avgTtfbMs,
              thruMbps: thruMbps,
            );
          }
          VodProxyLog.log(
            'probe id=$id host=${stat.host} ttfb=${stat.avgTtfbMs.toStringAsFixed(0)}ms '
            'thru=${thruMbps.toStringAsFixed(2)}Mbps status=ok',
          );
        } catch (e) {
          if (e is _Forbidden) {
            pool.dropQuiet(stat.url, reason: '403');
            VodProxyLog.log(
              'probe id=$id host=${stat.host} status=skip reason=403',
            );
            return;
          }
          pool.recordFailure(stat.url, reason: 'probe $e', probe: true);
          VodProxyLog.log(
            'probe id=$id host=${stat.host} status=fail reason=$e',
          );
        }
      }),
    );
    if (_closed) return;
    pool.markOverseasWinnerIfNeeded();
    final ranked = pool.topHosts(k: 6, kind: kind);
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
    if (start > _highWater) _highWater = start;
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
        if (pos > _highWater) _highWater = pos;
        _bytesDelivered += take;
        _servedChunks.add(idx);
        lastServeAt = DateTime.now();
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
    final started = DateTime.now();
    final expected = _chunkLen(idx);
    final range = ByteRange(idx * chunkSize, idx * chunkSize + expected);
    Object? lastError;
    var raced = false;
    var stuckSignaled = false;
    while (!_closed && epoch == _readEpoch) {
      final cached = _chunks[idx];
      if (cached != null) {
        if (cached.length == expected) return cached;
        _chunks.remove(idx);
        lastError = 'bad-length got=${cached.length} want=$expected';
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining.inMilliseconds <= 0) {
        throw VodServeAbort(
          range,
          lastError ?? 'deadline ${fetchBudget.inSeconds}s',
        );
      }
      if (lastError is VodServeAbort) throw lastError as VodServeAbort;

      unawaited(
        _chunk(idx, urgent: urgent).then<void>(
          (_) {},
          onError: (Object e) {
            lastError = e;
          },
        ),
      );

      final slice = remaining < cursorWatchdog ? remaining : cursorWatchdog;
      try {
        final inflight = _inflight[idx];
        await Future.any<void>([
          if (inflight != null) inflight.then<void>((_) {}),
          Future<void>.delayed(slice),
          _wake.future,
        ]);
      } catch (_) {}

      final ready = _chunks[idx];
      if (ready != null && ready.length == expected) return ready;
      if (lastError is VodServeAbort) throw lastError as VodServeAbort;
      if (_closed || epoch != _readEpoch) throw const _SessionClosed();

      final waited = DateTime.now().difference(started);
      if (!raced && waited >= cursorWatchdog) {
        raced = true;
        final avoid = _inflightHost[idx];
        VodProxyLog.log(
          'watchdog id=$id idx=$idx range=$range '
          'reason=no-progress ${cursorWatchdog.inMilliseconds}ms race',
        );
        unawaited(_raceChunk(idx, avoidHost: avoid));
        unawaited(_raceChunk(idx + 1, avoidHost: avoid));
      } else if (raced &&
          !stuckSignaled &&
          waited >= const Duration(seconds: 15)) {
        stuckSignaled = true;
        VodProxyLog.log(
          'abort id=$id range=$range reason=cursor-watchdog — holding client',
        );
        onCursorStuck?.call();
      }
    }
    throw const _SessionClosed();
  }

  void _noteFetchedExtent(int idx) {
    final end = idx * chunkSize + _chunkLen(idx);
    if (end > _highWater) _highWater = end;
  }

  Future<void> _raceChunk(int idx, {String? avoidHost}) async {
    try {
      final expected = _chunkLen(idx);
      final cached = _chunks[idx];
      if (cached != null && cached.length == expected) return;
      final size = fileSize;
      if (size == null || size <= 0) return;
      final start = idx * chunkSize;
      final end = min(start + chunkSize, size);
      final fetched = await _fetchRange(
        ByteRange(start, end),
        urgent: true,
        avoidHost: avoidHost,
      );
      final want = end - start;
      if (fetched.bytes.length != want) return;
      _chunks[idx] = fetched.bytes;
      _fetchedChunks.add(idx);
      _noteFetchedExtent(idx);
      _wakeWaiters();
    } on _SessionClosed {
      // Player moved on.
    } catch (e) {
      VodProxyLog.log('race-fail id=$id idx=$idx $e');
    }
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
        if (_fetchedChunks.contains(idx) && !_chunks.containsKey(idx)) {
          VodProxyLog.log('refetch id=$id idx=$idx reason=evicted');
        }
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
        _noteFetchedExtent(idx);
        return fetched.bytes;
      } finally {
        _inflight.remove(idx);
      }
    });
  }

  Future<({Uint8List bytes, int total})> _fetchRange(
    ByteRange range, {
    required bool urgent,
    String? avoidHost,
  }) async {
    Object? lastError;
    String? lastHost = avoidHost;
    final deadline = DateTime.now().add(fetchBudget);
    final idx = range.start ~/ chunkSize;
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      if (_closed) throw const _SessionClosed();
      attempt++;
      final remaining = deadline.difference(DateTime.now());
      if (remaining.inMilliseconds < 50) break;
      final allowBanned = attempt >= 4 && pool.available.isEmpty;
      String? url = pool.pickUrl(
        avoidHost: lastHost,
        allowBanned: allowBanned,
        kind: kind,
      );
      if (url == null || url.isEmpty) {
        final primary = pool.primaryUrl;
        if (primary.isNotEmpty && (!pool.isUrlBanned(primary) || allowBanned)) {
          url = primary;
        }
      }
      if (url == null || url.isEmpty) {
        lastError = 'no-host';
        await Future<void>.delayed(const Duration(milliseconds: 80));
        continue;
      }
      lastHost = Uri.tryParse(url)?.host;
      if (lastHost != null) _inflightHost[idx] = lastHost;
      final cap = urgent ? const Duration(seconds: 3) : attemptTimeout;
      final perTry = remaining < cap ? remaining : cap;
      try {
        final result = await _getOrKick(url, range, perTry);
        if (result.bytes.length != range.length) {
          retries++;
          lastError = _noteFetchFail(url, range, 'short-read');
          continue;
        }
        _bytesNet += result.bytes.length;
        return result;
      } on _HostKicked {
        lastError = 'kicked';
        await Future<void>.delayed(const Duration(milliseconds: 40));
        continue;
      } on _Forbidden {
        retries++;
        lastError = _noteFetchFail(
          url,
          range,
          '403',
          ban: const Duration(seconds: 45),
        );
      } on _SessionClosed {
        rethrow;
      } catch (e) {
        if (_closed) throw const _SessionClosed();
        retries++;
        lastError = _noteFetchFail(url, range, e);
      }
    }
    final why = lastError ?? 'deadline ${fetchBudget.inSeconds}s n=$attempt';
    VodProxyLog.log('abort id=$id range=$range reason=$why');
    throw VodServeAbort(range, why);
  }

  Object _noteFetchFail(
    String url,
    ByteRange range,
    Object reason, {
    Duration ban = VodHostPool.defaultBan,
  }) {
    final host = Uri.tryParse(url)?.host ?? url;
    if (pool.isUrlBanned(url) || VodHostHealth.instance.isBanned(host)) {
      VodProxyLog.log(
        'stale id=$id range=$range from=$host reason=already-banned $reason',
      );
      return reason;
    }
    final banned = pool.recordFailure(url, reason: reason.toString(), ban: ban);
    VodProxyLog.log(
      'retry id=$id range=$range from=$host reason=$reason',
    );
    if (banned) _kickFetches(fromHost: host);
    return reason;
  }

  Future<({Uint8List bytes, int total})> _getOrKick(
    String url,
    ByteRange range,
    Duration perTry,
  ) {
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    final epochAtStart = _kickEpoch;
    final done = Completer<({Uint8List bytes, int total})>();
    var settled = false;
    void settle(void Function() fn) {
      if (settled) return;
      settled = true;
      fn();
    }

    _get(url, range)
        .timeout(perTry)
        .then(
          (result) => settle(() => done.complete(result)),
          onError: (Object e, StackTrace st) =>
              settle(() => done.completeError(e, st)),
        );
    void watchKick() {
      _wake.future.then((_) {
        if (settled) return;
        if (_kickEpoch != epochAtStart && _kickedHost == host) {
          settle(() => done.completeError(const _HostKicked()));
          return;
        }
        watchKick();
      }, onError: (_) {});
    }

    watchKick();
    return done.future;
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
    final size = fileSize;
    if (size != null && size <= windowBytes + backBufferBytes) return;
    final keepFrom = (_cursor - backBufferBytes).clamp(0, 1 << 30);
    // Never drop already-fetched data ahead of the cursor; only trim far behind.
    _chunks.removeWhere((idx, _) {
      if (_inflight.containsKey(idx)) return false;
      final start = idx * chunkSize;
      return start + chunkSize < keepFrom;
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
    if (pausing) {
      pauseStats();
      return;
    }
    if (_endLogged) return;
    _endLogged = true;
    _statsTimer?.cancel();
    _statsTimer = null;
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
    _wakeWaiters();
    logSessionEnd(reason: reason);
    _chunks.clear();
    _inflight.clear();
    _inflightHost.clear();
    _client.close(force: true);
  }
}

class _Forbidden implements Exception {}

class _HostKicked implements Exception {
  const _HostKicked();
}

class _SessionClosed implements Exception {
  const _SessionClosed();
}
