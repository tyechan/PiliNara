import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
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
    pool.seedFromHealth(kind);
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

  /// Playhead connects die here, not at the 8s client default.
  static const Duration urgentConnectTimeout = Duration(milliseconds: 1500);

  /// Start a second node when the playhead chunk has produced no bytes.
  static const Duration playheadHedgeAfter = Duration(seconds: 1);

  static const Duration connectBanFor = Duration(seconds: 45);

  final HttpClient _client = _openClient(const Duration(seconds: 8));

  final HttpClient _urgentClient = _openClient(urgentConnectTimeout);

  static HttpClient _openClient(Duration connectTimeout) {
    return HttpClient()
      ..userAgent = BrowserUa.pc
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 20)
      ..autoUncompress = false;
  }

  /// Test hook. When set, replaces `HttpClient.getUrl` so a host can hang
  /// in TCP connect without a blackhole route.
  Future<HttpClientRequest> Function(Uri uri, {required bool urgent})?
  debugOpenRequest;

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
  final Map<int, Uint8List> _partial = {};
  final Map<int, int> _fetchGen = {};
  final Map<int, HttpClientRequest> _requests = {};
  final Map<int, List<_ReqBox>> _boxes = {};
  HttpClientRequest? _probeRequest;
  Object? _probeSeedOwner;
  int _seedInstalled = 0;
  int _winnerProbeEnd = 0;
  bool _winnerBodyDone = true;
  Future<void>? _winnerBody;

  bool get isClosed => _closed;

  int get bytesNet => _bytesNet;

  bool get statsRunning => _statsTimer != null;

  bool get statsPaused => _statsPaused;

  int get activeReads => _activeReads;

  int get inflightCount => _inflight.length;

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

  static const int probeBytes = 128 * 1024;

  bool _winnerCovers(int filePos) =>
      !_winnerBodyDone && _winnerProbeEnd > 0 && filePos < _winnerProbeEnd;

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
    pool.seedFromHealth(kind);
    final targets = pool.hosts.take(8).toList();
    if (targets.isEmpty) return;
    final firstOk = Completer<void>();
    var left = targets.length;
    for (final stat in targets) {
      unawaited(
        _probeOne(stat, firstOk, () {
          left--;
          if (left == 0) {
            if (!firstOk.isCompleted) firstOk.complete();
            _logProbeRank();
          }
        }),
      );
    }
    await firstOk.future;
  }

  Future<void> _probeOne(
    VodHostStat stat,
    Completer<void> firstOk,
    void Function() done,
  ) async {
    final bodyDone = Completer<void>();
    var won = false;
    try {
      if (_closed) return;
      await _get(
        stat.url,
        const ByteRange(0, probeBytes),
        probe: true,
        firstByteTimeout: const Duration(seconds: 3),
        stallTimeout: const Duration(seconds: 3),
        onReady: (total, req) {
          fileSize ??= total;
          if (_probeSeedOwner == null) {
            _probeSeedOwner = stat;
            won = true;
            _probeRequest = req;
            _winnerBodyDone = false;
            _winnerBody = bodyDone.future;
            _winnerProbeEnd = total > 0 && total < probeBytes
                ? total
                : probeBytes;
            if (!firstOk.isCompleted) firstOk.complete();
          }
        },
        onFileBytes: (offset, slice) {
          if (!identical(_probeSeedOwner, stat)) return;
          if (offset != _seedInstalled) return;
          _installSeed(slice, offset);
          _seedInstalled += slice.length;
        },
      );
      if (!identical(_probeSeedOwner, stat) && !won) {
        // Another host already unblocked startup. This one only ranks.
      }
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
    } on _FetchCancelled {
      // Seek moved off the opening bytes, or the session closed.
    } catch (e) {
      if (e is _Forbidden) {
        pool.dropQuiet(stat.url, reason: '403');
        VodProxyLog.log(
          'probe id=$id host=${stat.host} status=skip reason=403',
        );
      } else if (_connectLike(e)) {
        pool.banConnect(
          stat.url,
          reason: 'probe $e',
          ban: connectBanFor,
          countChunk: false,
        );
        VodProxyLog.log(
          'probe id=$id host=${stat.host} status=fail reason=$e',
        );
      } else {
        pool.recordFailure(stat.url, reason: 'probe $e', probe: true);
        VodProxyLog.log(
          'probe id=$id host=${stat.host} status=fail reason=$e',
        );
      }
    } finally {
      if (won || identical(_probeSeedOwner, stat)) {
        _winnerBodyDone = true;
        _probeRequest = null;
        if (!bodyDone.isCompleted) bodyDone.complete();
      }
      done();
    }
  }

  void _logProbeRank() {
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

  void _installSeed(Uint8List bytes, int fileStart) {
    if (bytes.isEmpty || fileStart < 0) return;
    var off = 0;
    var pos = fileStart;
    while (off < bytes.length) {
      final size = fileSize;
      if (size != null && pos >= size) break;
      final idx = pos ~/ chunkSize;
      final into = pos - idx * chunkSize;
      final full = _chunks[idx];
      final expected = _chunkLen(idx);
      if (full != null && full.length == expected) {
        final skip = full.length - into;
        if (skip <= 0 || off + skip > bytes.length) break;
        off += skip;
        pos += skip;
        continue;
      }
      final existing = _partial[idx]?.length ?? 0;
      if (into != existing) return;
      final room = expected - existing;
      if (room <= 0) return;
      final take = min(room, bytes.length - off);
      _appendPartial(idx, Uint8List.sublistView(bytes, off, off + take));
      _promoteIfComplete(idx);
      off += take;
      pos += take;
    }
  }

  void _appendPartial(int idx, Uint8List slice) {
    if (slice.isEmpty) return;
    final prev = _partial[idx];
    if (prev == null) {
      _partial[idx] = Uint8List.fromList(slice);
    } else {
      final merged = Uint8List(prev.length + slice.length);
      merged.setRange(0, prev.length, prev);
      merged.setRange(prev.length, merged.length, slice);
      _partial[idx] = merged;
    }
    _wakeWaiters();
  }

  void _promoteIfComplete(int idx) {
    final part = _partial[idx];
    if (part == null) return;
    final expected = _chunkLen(idx);
    if (part.length != expected) return;
    _chunks[idx] = part;
    _partial.remove(idx);
    _fetchedChunks.add(idx);
    _noteFetchedExtent(idx);
    _wakeWaiters();
  }

  Uint8List? _bytesReady(int idx) => _chunks[idx] ?? _partial[idx];

  Stream<List<int>> read(int start, int endExclusive) async* {
    if (_closed) return;
    final epoch = ++_readEpoch;
    _activeReads++;
    startStats();
    _cursor = start;
    if (start > _highWater) _highWater = start;
    if (start >= _winnerProbeEnd) _abortProbeBody();
    _cancelOutsideWindow(start);
    _evict();
    unawaited(_prefetch(start));
    final deadline = DateTime.now().add(fetchBudget);
    var stuckSignaled = false;
    var lastProgress = DateTime.now();
    try {
      var pos = start;
      while (!_closed && epoch == _readEpoch && pos < endExclusive) {
        final idx = pos ~/ chunkSize;
        final expected = _chunkLen(idx);
        final offset = pos - idx * chunkSize;
        final ready = _bytesReady(idx);
        if (ready != null && ready.length > offset) {
          final take = min(ready.length - offset, endExclusive - pos);
          if (take <= 0) {
            throw VodServeAbort(ByteRange(pos, endExclusive), 'empty-take');
          }
          yield Uint8List.fromList(
            Uint8List.sublistView(ready, offset, offset + take),
          );
          pos += take;
          _cursor = pos;
          if (pos > _highWater) _highWater = pos;
          _bytesDelivered += take;
          if (ready.length == expected ||
              (_chunks[idx]?.length ?? 0) == expected) {
            _servedChunks.add(idx);
          }
          lastServeAt = DateTime.now();
          lastProgress = DateTime.now();
          stuckSignaled = false;
          _evict();
          unawaited(_prefetch(pos));
          continue;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw VodServeAbort(
            ByteRange(pos, endExclusive),
            'deadline ${fetchBudget.inSeconds}s',
          );
        }
        if (_winnerCovers(pos)) {
          final wake = _wake.future;
          final winner = _winnerBody ?? Future<void>.value();
          await Future.any<void>([wake, winner]);
          if (_closed || epoch != _readEpoch) return;
          // async* cancel does not interrupt an await. An empty event lets a
          // dropped client stop this generator; the HTTP handler skips it.
          yield Uint8List(0);
          continue;
        }
        if (!_inflight.containsKey(idx)) {
          unawaited(
            _chunk(idx, urgent: true).then<void>(
              (_) {},
              onError: (Object e) {
                if (e is _SessionClosed || e is _FetchCancelled) return;
                VodProxyLog.log('cursor-fail id=$id idx=$idx $e');
              },
            ),
          );
        }
        final quietFor = DateTime.now().difference(lastProgress);
        if (!stuckSignaled && quietFor >= const Duration(seconds: 15)) {
          stuckSignaled = true;
          VodProxyLog.log(
            'abort id=$id range=${ByteRange(pos, endExclusive)} '
            'reason=cursor-watchdog — holding client',
          );
          onCursorStuck?.call();
        }
        final wake = _wake.future;
        await Future.any<void>([
          wake,
          Future<void>.delayed(const Duration(milliseconds: 200)),
        ]);
        if (_closed || epoch != _readEpoch) return;
        yield Uint8List(0);
      }
    } finally {
      _activeReads = (_activeReads - 1).clamp(0, 1 << 20);
    }
  }

  void _abortProbeBody() {
    if (_winnerBodyDone) return;
    _winnerBodyDone = true;
    final req = _probeRequest;
    _probeRequest = null;
    try {
      req?.abort(const _FetchCancelled());
    } catch (_) {}
    if (_winnerBody != null) {
      // The probe future completes itself in finally.
    }
  }

  void _cancelOutsideWindow(int from) {
    final size = fileSize;
    final until = size == null
        ? from + windowBytes
        : min(from + windowBytes, size);
    final lo = from ~/ chunkSize;
    var hi = lo;
    if (until > from) hi = (until - 1) ~/ chunkSize;
    final drop = <int>[
      for (final idx in _inflight.keys)
        if (idx < lo || idx > hi) idx,
    ];
    for (final idx in drop) {
      _abortChunk(idx);
      VodProxyLog.log('cancel-prefetch id=$id idx=$idx');
    }
  }

  void _abortChunk(int idx) {
    _fetchGen[idx] = (_fetchGen[idx] ?? 0) + 1;
    final req = _requests.remove(idx);
    _inflight.remove(idx);
    _inflightHost.remove(idx);
    _partial.remove(idx);
    final boxes = _boxes.remove(idx);
    if (boxes != null) {
      for (final box in boxes) {
        _abortBox(box);
      }
    }
    try {
      req?.abort(const _FetchCancelled());
    } catch (_) {}
  }

  Future<void> _prefetch(int from) async {
    final size = fileSize;
    if (size == null || size <= 0) return;
    final until = min(from + windowBytes, size);
    final ranges = splitRanges(from, until, chunkSize);
    var launched = 0;
    for (final range in ranges) {
      if (_closed) return;
      if (_winnerCovers(range.start)) continue;
      final idx = range.start ~/ chunkSize;
      // The cursor chunk is fetched as urgent so a hung connect can be hedged.
      if (idx == from ~/ chunkSize) continue;
      if (_chunks.containsKey(idx) || _inflight.containsKey(idx)) continue;
      if (_partial[idx]?.length == _chunkLen(idx)) continue;
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
    } on _FetchCancelled {
      // Seek left this chunk's window.
    } catch (e) {
      VodProxyLog.log('prefetch-fail id=$id idx=$idx $e');
    }
  }

  void _noteFetchedExtent(int idx) {
    final end = idx * chunkSize + _chunkLen(idx);
    if (end > _highWater) _highWater = end;
  }

  int _haveBytes(int idx) {
    final full = _chunks[idx];
    if (full != null) return full.length;
    return _partial[idx]?.length ?? 0;
  }

  Future<Uint8List> _chunk(int idx, {bool urgent = false}) {
    final expected = _chunkLen(idx);
    final cached = _chunks[idx];
    if (cached != null && cached.length == expected)
      return Future.value(cached);
    return _inflight.putIfAbsent(idx, () async {
      final gen = _fetchGen[idx] ?? 0;
      try {
        if (_closed) throw const _SessionClosed();
        final size = fileSize ?? await ensureSize();
        if (_closed) throw const _SessionClosed();
        if ((_fetchGen[idx] ?? 0) != gen) throw const _FetchCancelled();
        if (_fetchedChunks.contains(idx) && !_chunks.containsKey(idx)) {
          VodProxyLog.log('refetch id=$id idx=$idx reason=evicted');
        }
        final chunkStart = idx * chunkSize;
        final end = min(chunkStart + chunkSize, size);
        while (_haveBytes(idx) < end - chunkStart) {
          if ((_fetchGen[idx] ?? 0) != gen) throw const _FetchCancelled();
          final have = _haveBytes(idx);
          final start = chunkStart + have;
          if (start >= end) break;
          if (urgent) {
            await _fetchPlayhead(idx, gen, ByteRange(start, end));
          } else {
            await _fetchRange(
              ByteRange(start, end),
              urgent: false,
              liveIdx: idx,
              fetchGen: gen,
              onFileBytes: (offset, slice) {
                _acceptFileBytes(idx, gen, offset, slice);
              },
            );
          }
          if (_haveBytes(idx) <= have) {
            throw StateError('no-progress idx=$idx at=$have');
          }
        }
        _promoteIfComplete(idx);
        final done = _chunks[idx];
        final want = end - chunkStart;
        if (done == null || done.length != want) {
          throw StateError(
            'chunk-len got=${done?.length ?? _haveBytes(idx)} want=$want',
          );
        }
        return done;
      } finally {
        if ((_fetchGen[idx] ?? 0) == gen) {
          _inflight.remove(idx);
          _requests.remove(idx);
          _inflightHost.remove(idx);
        }
      }
    });
  }

  void _acceptFileBytes(int idx, int gen, int offset, Uint8List slice) {
    if ((_fetchGen[idx] ?? 0) != gen || slice.isEmpty) return;
    final want = idx * chunkSize + _haveBytes(idx);
    if (offset != want) return;
    _appendPartial(idx, slice);
    _promoteIfComplete(idx);
  }

  bool _connectLike(Object error) {
    if (error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException ||
        error is TlsException) {
      return true;
    }
    final text = error.toString();
    return text.contains('Connection closed') ||
        text.contains('Connection refused') ||
        text.contains('Connection timed out') ||
        text.contains('connect timed out');
  }

  void _trackBox(int idx, _ReqBox box) {
    _boxes.putIfAbsent(idx, () => <_ReqBox>[]).add(box);
  }

  void _dropBox(int idx, _ReqBox box) {
    _boxes[idx]?.remove(box);
  }

  /// Playhead fetch. Connect and headers share one deadline, and if no bytes
  /// arrive within [playheadHedgeAfter] the remaining range is also requested
  /// from the next-best node. The first contiguous bytes win; the other
  /// request is aborted.
  Future<void> _fetchPlayhead(int idx, int gen, ByteRange range) async {
    final urlA = _pickHost(null);
    if (urlA == null) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      throw StateError('no-host');
    }
    final before = _haveBytes(idx);
    final boxA = _ReqBox();
    _ReqBox? boxB;
    var dropA = false;
    var dropB = false;
    var doneA = false;
    var doneB = false;
    Object? errorA;
    Object? errorB;

    void take(int source, int offset, Uint8List slice) {
      if (source == 1 && dropA) return;
      if (source == 2 && dropB) return;
      final want = idx * chunkSize + _haveBytes(idx);
      final had = _haveBytes(idx);
      _acceptFileBytes(idx, gen, offset, slice);
      if (_haveBytes(idx) <= had || offset != want) return;
      _bytesNet += slice.length;
      if (source == 1) {
        dropB = true;
        final other = boxB;
        if (other != null) _abortBox(other);
      } else {
        dropA = true;
        _abortBox(boxA);
      }
    }

    final futA = _getOrKick(
      urlA,
      range,
      urgent: true,
      liveIdx: idx,
      fetchGen: gen,
      onFileBytes: (offset, slice) => take(1, offset, slice),
      abandoned: () => dropA,
      box: boxA,
      track: idx,
    );
    unawaited(
      futA.then<void>(
        (_) {
          doneA = true;
        },
        onError: (Object e) {
          doneA = true;
          errorA = e;
        },
      ),
    );

    Future<void> waitUntil(bool Function() stop) async {
      while (!stop()) {
        if (_closed) throw const _SessionClosed();
        if ((_fetchGen[idx] ?? 0) != gen) throw const _FetchCancelled();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }

    final hedgeAt = DateTime.now().add(playheadHedgeAfter);
    await waitUntil(
      () =>
          _haveBytes(idx) > before ||
          doneA ||
          !DateTime.now().isBefore(hedgeAt),
    );
    if (_haveBytes(idx) > before) {
      await _awaitLeader(futA, () => dropA);
      return;
    }
    if (errorA is _SessionClosed) throw const _SessionClosed();
    if (errorA is _FetchCancelled && (_fetchGen[idx] ?? 0) != gen) {
      throw const _FetchCancelled();
    }
    final hostA = Uri.tryParse(urlA)?.host ?? urlA;
    final urlB = _pickHost(hostA);
    if (urlB == null || urlB == urlA) {
      if (!doneA) {
        try {
          await futA;
        } catch (e) {
          _noteConnectFail(urlA, range, e);
          rethrow;
        }
        return;
      }
      _noteConnectFail(urlA, range, errorA ?? 'no-bytes');
      throw errorA ?? StateError('no-progress idx=$idx');
    }
    _noteConnectFail(
      urlA,
      range,
      errorA ?? 'no-bytes ${playheadHedgeAfter.inMilliseconds}ms',
    );
    VodProxyLog.log(
      'hedge id=$id idx=$idx range=$range from=$hostA '
      'alt=${Uri.tryParse(urlB)?.host ?? urlB}',
    );
    retries++;
    final hedgeBox = _ReqBox();
    boxB = hedgeBox;
    final futB = _getOrKick(
      urlB,
      range,
      urgent: true,
      liveIdx: idx,
      fetchGen: gen,
      onFileBytes: (offset, slice) => take(2, offset, slice),
      abandoned: () => dropB,
      box: hedgeBox,
      track: idx,
    );
    unawaited(
      futB.then<void>(
        (_) {
          doneB = true;
        },
        onError: (Object e) {
          doneB = true;
          errorB = e;
        },
      ),
    );
    await waitUntil(() => _haveBytes(idx) > before || (doneA && doneB));
    if (_haveBytes(idx) > before) {
      if (dropA) {
        await _awaitLeader(futB, () => dropB);
      } else {
        dropB = true;
        _abortBox(hedgeBox);
        await _awaitLeader(futA, () => dropA);
      }
      return;
    }
    if (errorB is _SessionClosed) throw const _SessionClosed();
    if (errorB is _FetchCancelled && (_fetchGen[idx] ?? 0) != gen) {
      throw const _FetchCancelled();
    }
    _noteConnectFail(urlB, range, errorB ?? errorA ?? 'no-bytes');
    throw errorB ?? errorA ?? StateError('no-progress idx=$idx');
  }

  Future<void> _awaitLeader<T>(
    Future<T> future,
    bool Function() dropped,
  ) async {
    try {
      await future;
    } on _FetchCancelled {
      if (!dropped()) rethrow;
    } on _HostKicked {
      if (!dropped()) rethrow;
    }
  }

  String? _pickHost(String? avoid) {
    final allowBanned = pool.available.isEmpty;
    var url = pool.pickUrl(
      avoidHost: avoid,
      allowBanned: allowBanned,
      kind: kind,
    );
    if (url == null || url.isEmpty) {
      final primary = pool.primaryUrl;
      if (primary.isNotEmpty && (allowBanned || !pool.isUrlBanned(primary))) {
        if (avoid == null || Uri.tryParse(primary)?.host != avoid) {
          url = primary;
        }
      }
    }
    if (url == null || url.isEmpty) return null;
    return url;
  }

  void _noteConnectFail(String url, ByteRange range, Object reason) {
    if (reason is _SessionClosed ||
        reason is _FetchCancelled ||
        reason is _HostKicked) {
      return;
    }
    if (!_connectLike(reason) && !reason.toString().startsWith('no-bytes')) {
      _noteFetchFail(url, range, reason);
      return;
    }
    final banned = pool.banConnect(
      url,
      reason: reason.toString(),
      ban: connectBanFor,
    );
    VodProxyLog.log(
      'retry id=$id range=$range from=${Uri.tryParse(url)?.host ?? url} '
      'reason=$reason${banned ? '' : ' (already-banned)'}',
    );
  }

  void _abortBox(_ReqBox box) {
    try {
      box.req?.abort(const _FetchCancelled());
    } catch (_) {}
  }

  Duration _firstByteTimeout(bool urgent) {
    const urgentCap = Duration(seconds: 3);
    if (!urgent) return attemptTimeout;
    return attemptTimeout < urgentCap ? attemptTimeout : urgentCap;
  }

  Duration _stallTimeout() =>
      cursorWatchdog < attemptTimeout ? cursorWatchdog : attemptTimeout;

  Future<({Uint8List bytes, int total})> _fetchRange(
    ByteRange range, {
    required bool urgent,
    String? avoidHost,
    int? liveIdx,
    int? fetchGen,
    void Function(int offset, Uint8List slice)? onFileBytes,
  }) async {
    Object? lastError;
    String? lastHost = avoidHost;
    final deadline = DateTime.now().add(fetchBudget);
    final idx = liveIdx ?? range.start ~/ chunkSize;
    var attempt = 0;
    var cursor = range.start;
    var total = fileSize ?? 0;
    final assembled = onFileBytes == null ? BytesBuilder(copy: false) : null;
    while (cursor < range.endExclusive && DateTime.now().isBefore(deadline)) {
      if (_closed) throw const _SessionClosed();
      if (fetchGen != null && (_fetchGen[idx] ?? 0) != fetchGen) {
        throw const _FetchCancelled();
      }
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
      final piece = ByteRange(cursor, range.endExclusive);
      try {
        final result = await _getOrKick(
          url,
          piece,
          urgent: urgent,
          liveIdx: liveIdx,
          fetchGen: fetchGen,
          onFileBytes: onFileBytes,
        );
        if (result.bytes.isEmpty) {
          retries++;
          lastError = _noteFetchFail(url, piece, 'empty');
          continue;
        }
        total = result.total;
        if (assembled != null) assembled.add(result.bytes);
        _bytesNet += result.bytes.length;
        cursor += result.bytes.length;
        if (result.complete || cursor >= range.endExclusive) {
          return (
            bytes: assembled?.takeBytes() ?? Uint8List(0),
            total: total,
          );
        }
        retries++;
        lastError = _noteFetchFail(url, piece, 'stall');
      } on _FetchCancelled {
        rethrow;
      } on _HostKicked {
        lastError = 'kicked';
        await Future<void>.delayed(const Duration(milliseconds: 40));
      } on _Forbidden {
        retries++;
        lastError = _noteFetchFail(
          url,
          piece,
          '403',
          ban: const Duration(seconds: 45),
        );
      } on _SessionClosed {
        rethrow;
      } catch (e) {
        if (_closed) throw const _SessionClosed();
        retries++;
        lastError = _noteFetchFail(url, piece, e);
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

  Future<_RangeBody> _getOrKick(
    String url,
    ByteRange range, {
    required bool urgent,
    int? liveIdx,
    int? fetchGen,
    bool probe = false,
    void Function(int total, HttpClientRequest req)? onReady,
    void Function(int offset, Uint8List slice)? onFileBytes,
    bool Function()? abandoned,
    _ReqBox? box,
    int? track,
  }) {
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    final epochAtStart = _kickEpoch;
    final slot = box ?? _ReqBox();
    if (track != null) _trackBox(track, slot);
    var stop = false;
    final future = _get(
      url,
      range,
      probe: probe,
      urgent: urgent,
      liveIdx: liveIdx,
      fetchGen: fetchGen,
      onReady: onReady,
      onFileBytes: onFileBytes,
      box: slot,
      abandoned: abandoned,
    );
    // A second listener so the kick-watcher can stop. Its future must handle
    // the same error the caller awaits, or a timeout/cancel is also uncaught.
    unawaited(
      future.then<void>(
        (_) {
          stop = true;
        },
        onError: (Object _) {
          stop = true;
        },
      ),
    );
    if (track != null) {
      unawaited(
        future.then<void>(
          (_) {
            _dropBox(track, slot);
          },
          onError: (_) {
            _dropBox(track, slot);
          },
        ),
      );
    }
    void watchKick() {
      _wake.future.then((_) {
        if (stop) return;
        if (_kickEpoch != epochAtStart && _kickedHost == host) {
          try {
            slot.req?.abort(const _HostKicked());
          } catch (_) {}
          return;
        }
        watchKick();
      }, onError: (_) {});
    }

    watchKick();
    return future;
  }

  Future<_RangeBody> _get(
    String url,
    ByteRange range, {
    bool probe = false,
    bool urgent = false,
    int? liveIdx,
    int? fetchGen,
    void Function(int total, HttpClientRequest req)? onReady,
    void Function(int offset, Uint8List slice)? onFileBytes,
    _ReqBox? box,
    bool Function()? abandoned,
    Duration? firstByteTimeout,
    Duration? stallTimeout,
  }) async {
    final firstByte = firstByteTimeout ?? _firstByteTimeout(urgent || probe);
    final stall = stallTimeout ?? _stallTimeout();
    final sw = Stopwatch()..start();
    final deadline = DateTime.now().add(firstByte);
    Duration left() {
      final ms = deadline.difference(DateTime.now()).inMilliseconds;
      return Duration(milliseconds: ms < 1 ? 0 : ms);
    }

    void giveUp(HttpClientRequest? request) {
      if (abandoned?.call() != true) return;
      try {
        request?.abort(const _FetchCancelled());
      } catch (_) {}
      throw const _FetchCancelled();
    }

    final playhead = urgent && !probe;
    final uri = Uri.parse(url);
    final hook = debugOpenRequest;
    final Future<HttpClientRequest> opening = hook != null
        ? hook(uri, urgent: playhead)
        : (playhead ? _urgentClient : _client).getUrl(uri);
    final HttpClientRequest req;
    try {
      req = await opening.timeout(left());
    } on TimeoutException {
      throw TimeoutException('connect $range');
    }
    giveUp(req);
    box?.req = req;
    if (liveIdx != null) _requests[liveIdx] = req;
    req.headers.set(HttpHeaders.refererHeader, HttpString.baseUrl);
    req.headers.set(HttpHeaders.userAgentHeader, BrowserUa.pc);
    req.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=${range.start}-${range.endInclusive}',
    );
    req.followRedirects = true;
    void ensureLive() {
      if (_closed) throw const _SessionClosed();
      if (liveIdx != null &&
          fetchGen != null &&
          (_fetchGen[liveIdx] ?? 0) != fetchGen) {
        throw const _FetchCancelled();
      }
    }

    ensureLive();
    giveUp(req);
    final HttpClientResponse resp;
    try {
      resp = await req.close().timeout(left());
    } on TimeoutException {
      try {
        req.abort(TimeoutException('headers'));
      } catch (_) {}
      rethrow;
    }
    final ttfbMs = sw.elapsedMilliseconds;
    if (firstTtfbMs == 0) firstTtfbMs = ttfbMs;
    if (resp.statusCode == 403) {
      await resp.drain<void>().catchError((_) {});
      throw _Forbidden();
    }

    final int expect;
    final int total;
    var skipLeft = 0;
    if (resp.statusCode == 206) {
      final parsed = ContentRangeReply.parse(
        resp.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (parsed == null || parsed.start > range.start) {
        throw StateError(
          'bad Content-Range ${resp.headers.value(HttpHeaders.contentRangeHeader)} for $range',
        );
      }
      fileSize ??= parsed.total;
      total = parsed.total;
      onReady?.call(total, req);
      final available = parsed.total - range.start;
      if (available <= 0) {
        throw StateError('Content-Range $parsed missed $range');
      }
      expect = min(range.length, available);
      skipLeft = range.start - parsed.start;
    } else if (resp.statusCode == 200 && range.start == 0) {
      final cl = int.tryParse(
        resp.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (cl != null && cl > 0) fileSize ??= cl;
      total = fileSize ?? cl ?? 0;
      if (total > 0) onReady?.call(total, req);
      expect = total > 0 ? min(range.length, total) : range.length;
    } else {
      throw StateError('http ${resp.statusCode}');
    }

    final builder = BytesBuilder(copy: false);
    var taken = 0;
    var clean = true;
    var kicked = false;
    final iterator = StreamIterator<List<int>>(resp);
    var limit = firstByte;
    try {
      while (taken < expect) {
        ensureLive();
        if (abandoned?.call() == true) {
          giveUp(req);
        }
        if (_kickEpoch != 0 &&
            box != null &&
            _kickedHost == (Uri.tryParse(url)?.host ?? '').toLowerCase() &&
            _requests[liveIdx ?? -2] != req) {
          // Kick is observed via abort below.
        }
        bool ok;
        try {
          ok = await iterator.moveNext().timeout(limit);
        } on TimeoutException {
          clean = false;
          try {
            req.abort(TimeoutException('no-bytes'));
          } catch (_) {}
          break;
        } catch (e) {
          clean = false;
          kicked = e is _HostKicked;
          break;
        }
        if (!ok) break;
        limit = stall;
        var data = iterator.current;
        if (data is! Uint8List) data = Uint8List.fromList(data);
        if (skipLeft > 0) {
          if (data.length <= skipLeft) {
            skipLeft -= data.length;
            continue;
          }
          data = Uint8List.sublistView(data, skipLeft);
          skipLeft = 0;
        }
        final room = expect - taken;
        if (data.length > room) {
          data = Uint8List.sublistView(data, 0, room);
        }
        final slice = Uint8List.fromList(data);
        builder.add(slice);
        onFileBytes?.call(range.start + taken, slice);
        taken += slice.length;
      }
    } finally {
      await iterator.cancel();
    }
    final bytes = builder.takeBytes();
    final complete = clean && taken == expect && taken > 0;
    if (complete) {
      pool.recordSuccess(
        url,
        bytes: bytes.length,
        elapsedMs: sw.elapsedMilliseconds,
        ttfbMs: ttfbMs,
        probe: probe,
        kind: kind,
      );
      return _RangeBody(bytes: bytes, total: total, complete: true);
    }
    if (taken == 0) {
      if (kicked) throw const _HostKicked();
      throw TimeoutException('no-bytes $range');
    }
    if (probe) {
      throw StateError('probe-short got=$taken want=$expect');
    }
    return _RangeBody(bytes: bytes, total: total, complete: false);
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
    _abortProbeBody();
    for (final req in _requests.values.toList()) {
      try {
        req.abort(const _SessionClosed());
      } catch (_) {}
    }
    for (final boxes in _boxes.values) {
      for (final box in boxes) {
        try {
          box.req?.abort(const _SessionClosed());
        } catch (_) {}
      }
    }
    _requests.clear();
    _boxes.clear();
    _wakeWaiters();
    logSessionEnd(reason: reason);
    _chunks.clear();
    _partial.clear();
    _inflight.clear();
    _inflightHost.clear();
    _client.close(force: true);
    _urgentClient.close(force: true);
  }
}

class _RangeBody {
  const _RangeBody({
    required this.bytes,
    required this.total,
    required this.complete,
  });

  final Uint8List bytes;
  final int total;
  final bool complete;
}

class _ReqBox {
  HttpClientRequest? req;
}

class _Forbidden implements Exception {}

class _FetchCancelled implements Exception {
  const _FetchCancelled();
}

class _HostKicked implements Exception {
  const _HostKicked();
}

class _SessionClosed implements Exception {
  const _SessionClosed();
}
