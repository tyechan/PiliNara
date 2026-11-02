import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_health.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_pool.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_range.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_session.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// Loopback HTTP proxy that mpv reads from. Upstream bytes are fetched with
/// parallel validated Range requests across several CDN hosts.
class VodHttpProxy {
  VodHttpProxy._();
  static final VodHttpProxy instance = VodHttpProxy._();

  HttpServer? _server;
  int? port;
  final Map<String, VodSession> _sessions = {};
  final Map<String, VodSession> _lingering = {};
  final Map<String, Timer> _lingerTimers = {};
  static const Duration lingerClosedFor = Duration(seconds: 5);
  static const Duration defaultOrphanAfter = Duration(seconds: 8);
  Duration orphanAfter = defaultOrphanAfter;
  int _seq = 0;
  bool _forceDirectOnce = false;
  DateTime? lastRequestAt;
  int requestsServed = 0;
  void Function()? onCursorStuck;
  Future<void> _wrapTail = Future<void>.value();
  Timer? _orphanWatch;
  String? _currentVideoId;
  String? _currentAudioId;

  bool get isRunning => _server != null && port != null;

  bool get hasActiveSession => _sessions.isNotEmpty;

  Iterable<VodSession> get debugSessions => _sessions.values;

  Iterable<VodSession> get debugLingering => _lingering.values;

  void forceDirectOnce() {
    _forceDirectOnce = true;
    _currentVideoId = null;
    _currentAudioId = null;
    closeAll(reason: 'force-direct');
  }

  bool mentionsActiveSession(String text) {
    for (final id in _sessions.keys) {
      if (text.contains('/$id') || text.contains(id)) return true;
    }
    return false;
  }

  Future<T> _withWrapLock<T>(Future<T> Function() fn) {
    final done = Completer<void>();
    final prev = _wrapTail;
    _wrapTail = done.future;
    return () async {
      try {
        await prev;
        return await fn();
      } finally {
        done.complete();
      }
    }();
  }

  void closeAll({String reason = 'close'}) {
    final hard =
        reason == 'reset-test' ||
        reason == 'dispose' ||
        reason == 'force-direct';
    if (_sessions.isEmpty && (!hard || _lingering.isEmpty)) return;
    if (_sessions.isNotEmpty) {
      VodProxyLog.log('close reason=$reason n=${_sessions.length}');
    }
    final moving = Map<String, VodSession>.from(_sessions);
    _sessions.clear();
    if (hard) {
      _currentVideoId = null;
      _currentAudioId = null;
    }
    for (final e in moving.entries) {
      if (hard) {
        e.value.close(reason: reason);
      } else {
        _park(e.key, e.value);
      }
    }
    if (hard) _flushLingering(reason);
    _syncOrphanWatch();
  }

  void _park(String id, VodSession session) {
    _lingering[id] = session;
    _lingerTimers[id]?.cancel();
    _lingerTimers[id] = Timer(lingerClosedFor, () {
      _lingerTimers.remove(id);
      final parked = _lingering.remove(id);
      parked?.close(reason: 'linger-expired');
    });
  }

  void _flushLingering(String reason) {
    for (final timer in _lingerTimers.values) {
      timer.cancel();
    }
    _lingerTimers.clear();
    for (final session in _lingering.values) {
      if (!session.isClosed) session.close(reason: reason);
    }
    _lingering.clear();
  }

  VodSession? _lookup(String id) {
    final active = _sessions[id];
    if (active != null) return active;
    final parked = _lingering.remove(id);
    if (parked == null) return null;
    _lingerTimers.remove(id)?.cancel();
    _sessions[id] = parked;
    VodProxyLog.log('session-reclaim id=$id');
    _syncOrphanWatch();
    return parked;
  }

  void _armOrphanWatch() {
    _orphanWatch ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _sweepOrphans();
    });
  }

  void _syncOrphanWatch() {
    if (_sessions.isEmpty && _lingering.isEmpty) {
      _orphanWatch?.cancel();
      _orphanWatch = null;
      return;
    }
    _armOrphanWatch();
  }

  void _sweepOrphans() {
    final now = DateTime.now();
    final stale = <String>[];
    for (final e in _sessions.entries) {
      if (e.key == _currentVideoId || e.key == _currentAudioId) continue;
      if (e.value.activeReads > 0) continue;
      final last = e.value.lastClientAt ?? e.value.startedAt;
      if (now.difference(last) < orphanAfter) continue;
      stale.add(e.key);
    }
    for (final e in _lingering.entries) {
      if (e.value.activeReads > 0) continue;
      final last = e.value.lastClientAt ?? e.value.startedAt;
      if (now.difference(last) < orphanAfter) continue;
      stale.add(e.key);
    }
    for (final id in stale) {
      final session = _sessions.remove(id) ?? _lingering.remove(id);
      _lingerTimers.remove(id)?.cancel();
      session?.close(reason: 'orphan');
    }
    _syncOrphanWatch();
  }

  Future<void> resetForTest() async {
    VodProxyLog.resetForTest();
    VodHostHealth.instance.resetForTest();
    closeAll(reason: 'reset-test');
    _seq = 0;
    _forceDirectOnce = false;
    requestsServed = 0;
    lastRequestAt = null;
    onCursorStuck = null;
    orphanAfter = defaultOrphanAfter;
    _currentVideoId = null;
    _currentAudioId = null;
    _orphanWatch?.cancel();
    _orphanWatch = null;
    final server = _server;
    _server = null;
    port = null;
    await server?.close(force: true);
  }

  String? get preferredHost =>
      _sessions.isEmpty ? null : _sessions.values.first.pool.preferred?.host;

  String hostsFor(String kind) {
    for (final session in _sessions.values) {
      if (session.kind != kind) continue;
      final hosts = session.pool
          .topHosts(k: 3, kind: session.kind)
          .map((h) => h.host)
          .join(',');
      return hosts.isEmpty ? '-' : hosts;
    }
    return '-';
  }

  void markFallback(String reason) {
    for (final session in _sessions.values) {
      session.fallbackReason = reason;
    }
  }

  void flushSessionEnd({String reason = 'pause'}) {
    if (_sessions.isEmpty) return;
    for (final session in _sessions.values) {
      session.logSessionEnd(reason: reason);
    }
  }

  void resumeStats() {
    for (final session in _sessions.values) {
      session.resumeStats();
    }
  }

  Future<bool> ensureStarted() async {
    if (isRunning) return true;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.autoCompress = false;
      _server = server;
      port = server.port;
      server.listen((request) {
        unawaited(_handle(request));
      });
      var threads = 6;
      var chunkKb = 512;
      var windowMb = 32;
      try {
        threads = Pref.vodMultiConnThreads;
        chunkKb = Pref.vodMultiConnChunkKb;
        windowMb = Pref.vodMultiConnWindowMb;
      } catch (_) {}
      VodProxyLog.log(
        'listen 127.0.0.1:$port threads=$threads '
        'chunk=${chunkKb}KB window=${windowMb}MB',
      );
      return true;
    } catch (e) {
      VodProxyLog.log('listen-failed $e');
      _server = null;
      port = null;
      return false;
    }
  }

  Future<NetworkSource?> wrap(NetworkSource source) {
    return _withWrapLock(() => _wrapUnlocked(source));
  }

  Future<NetworkSource?> _wrapUnlocked(NetworkSource source) async {
    if (_forceDirectOnce) {
      _forceDirectOnce = false;
      _currentVideoId = null;
      _currentAudioId = null;
      closeAll(reason: 'force-direct');
      VodProxyLog.log('wrap-skip force-direct');
      return null;
    }
    if (source.videoSource.startsWith('edl://') ||
        source.videoSource.startsWith('http://127.0.0.1')) {
      return null;
    }
    if (!await ensureStarted()) return null;
    closeAll(reason: 'new-wrap');
    final videoId = _register(
      kind: 'video',
      primary: source.videoSource,
      extras: source.videoCandidates,
    );
    final videoSession = _sessions[videoId];
    if (videoSession == null) return null;
    try {
      await videoSession.ensureSize();
    } catch (e) {
      VodProxyLog.log('probe-failed video $e — using direct URL');
      videoSession.fallbackReason = e.toString();
      videoSession.close(reason: 'probe-failed');
      _sessions.remove(videoId);
      _currentVideoId = null;
      return null;
    }
    String? audio;
    if (source.audioSource case final a? when a.isNotEmpty) {
      final audioId = _register(
        kind: 'audio',
        primary: a,
        extras: source.audioCandidates,
      );
      final audioSession = _sessions[audioId];
      try {
        await audioSession!.ensureSize();
        audio = _url(audioId);
        _currentAudioId = audioId;
      } catch (e) {
        VodProxyLog.log('probe-failed audio $e — using direct audio');
        audioSession?.fallbackReason = e.toString();
        audioSession?.close(reason: 'probe-failed');
        _sessions.remove(audioId);
        audio = a;
        _currentAudioId = null;
      }
    } else {
      _currentAudioId = null;
    }
    _currentVideoId = videoId;
    final video = _url(videoId);
    final vHosts =
        _sessions[videoId]?.pool
            .topHosts(k: 3, kind: 'video')
            .map((h) => h.host)
            .join(',') ??
        '-';
    final aId = audio != null && audio.startsWith('http://127.0.0.1')
        ? audio.split('/').last
        : null;
    final aHosts = aId == null
        ? '-'
        : (_sessions[aId]?.pool
                  .topHosts(k: 3, kind: 'audio')
                  .map((h) => h.host)
                  .join(',') ??
              '-');
    VodProxyLog.log(
      'wrap video=$video audio=${audio ?? '-'} '
      'srcHost=${Uri.tryParse(source.videoSource)?.host ?? '-'} '
      'size=${_sessions[videoId]?.fileSize ?? -1} '
      'videoHosts=$vHosts audioHosts=$aHosts',
    );
    return NetworkSource(
      videoSource: video,
      audioSource: audio,
      videoCandidates: source.videoCandidates,
      audioCandidates: source.audioCandidates,
    );
  }

  /// Test helper: register one upstream URL and return the loopback URL.
  Future<String?> openRaw(
    String primary, {
    String kind = 'video',
    int chunkSize = 512 * 1024,
    int windowBytes = 8 * 1024 * 1024,
    int workers = 4,
    Duration? attemptTimeout,
    Duration? fetchBudget,
    Duration? cursorWatchdog,
    int? backBufferBytes,
    List<String> extras = const [],
  }) {
    return _withWrapLock(() async {
      if (!await ensureStarted()) return null;
      final id = _register(
        kind: kind,
        primary: primary,
        extras: extras,
        chunkSize: chunkSize,
        windowBytes: windowBytes,
        workers: workers,
        attemptTimeout: attemptTimeout,
        fetchBudget: fetchBudget,
        cursorWatchdog: cursorWatchdog,
        backBufferBytes: backBufferBytes,
        expandHosts: false,
      );
      try {
        await _sessions[id]!.ensureSize();
      } catch (e) {
        VodProxyLog.log('openRaw-probe-failed $e');
        _sessions[id]?.close(reason: 'probe-failed');
        _sessions.remove(id);
        return null;
      }
      if (kind == 'audio') {
        _currentAudioId = id;
      } else {
        _currentVideoId = id;
      }
      return _url(id);
    });
  }

  String _register({
    required String kind,
    required String primary,
    required List<String> extras,
    int? chunkSize,
    int? windowBytes,
    int? workers,
    Duration? attemptTimeout,
    Duration? fetchBudget,
    Duration? cursorWatchdog,
    int? backBufferBytes,
    bool expandHosts = true,
  }) {
    final id = '$kind${++_seq}';
    final candidates = expandHosts
        ? VodHostPool.buildCandidates(primary, extras: extras)
        : [primary, ...extras];
    int fallbackChunk() {
      try {
        return Pref.vodMultiConnChunkKb * 1024;
      } catch (_) {
        return 512 * 1024;
      }
    }

    int fallbackWindow() {
      try {
        return Pref.vodMultiConnWindowMb * 1024 * 1024;
      } catch (_) {
        return 32 * 1024 * 1024;
      }
    }

    int fallbackWorkers() {
      try {
        return Pref.vodMultiConnThreads.clamp(1, 16);
      } catch (_) {
        return 4;
      }
    }

    final session = VodSession(
      id: id,
      kind: kind,
      candidates: candidates.isEmpty ? [primary] : candidates,
      chunkSize: chunkSize ?? fallbackChunk(),
      windowBytes: windowBytes ?? fallbackWindow(),
      workers: workers ?? fallbackWorkers(),
      attemptTimeout: attemptTimeout ?? const Duration(seconds: 6),
      fetchBudget: fetchBudget ?? const Duration(seconds: 45),
      cursorWatchdog: cursorWatchdog ?? const Duration(milliseconds: 2500),
      backBufferBytes: backBufferBytes,
    );
    session.onCursorStuck = () => onCursorStuck?.call();
    session.noteClient();
    _sessions[id] = session;
    _syncOrphanWatch();
    return id;
  }

  String _url(String id) => 'http://127.0.0.1:$port/$id';

  static bool _clientGone(Object? e) {
    if (e == null) return false;
    final msg = e.toString();
    return msg.contains('Content size below specified contentLength') ||
        msg.contains('Broken pipe') ||
        msg.contains('Connection reset') ||
        msg.contains('Connection closed');
  }

  bool preferNextHost() {
    var any = false;
    for (final session in _sessions.values) {
      if (session.preferNextHost()) any = true;
    }
    return any;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final id = request.uri.pathSegments.isEmpty
          ? ''
          : request.uri.pathSegments.first;
      final session = _lookup(id);
      if (session == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      session.noteClient();
      final size = await session.ensureSize();
      if (size <= 0) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }
      lastRequestAt = DateTime.now();
      requestsServed++;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final parsed = HttpRangeRequest.parse(rangeHeader);
      final range = (parsed ?? const HttpRangeRequest(start: 0)).resolve(size);
      if (range.length <= 0) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await response.close();
        return;
      }

      final hasRange = parsed != null;
      response.statusCode = hasRange
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      response.headers.chunkedTransferEncoding = false;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      if (hasRange) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.endInclusive}/$size',
        );
      }
      response.headers.contentLength = range.length;
      response.bufferOutput = false;
      VodProxyLog.log(
        'req id=$id method=${request.method} range=${rangeHeader ?? '-'} '
        'status=${response.statusCode} bytes=${range.length}',
      );

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      await for (final chunk in session.read(range.start, range.endExclusive)) {
        if (chunk.isEmpty) continue;
        response.add(chunk);
        await response.flush();
      }
      await response.close();
    } catch (e) {
      if (e is VodServeAbort) {
        VodProxyLog.log(
          'abort id=${request.uri.pathSegments.isEmpty ? '-' : request.uri.pathSegments.first} '
          'range=${e.range} reason=${e.reason}',
        );
      } else if (_clientGone(e)) {
        VodProxyLog.log('req-client-gone ${request.uri.path} $e');
      } else {
        VodProxyLog.log('req-fail ${request.uri.path} $e');
      }
      try {
        if (!response.headers.chunkedTransferEncoding &&
            response.contentLength == 0) {
          response.statusCode = HttpStatus.badGateway;
        }
        await response.close();
      } catch (_) {}
    }
  }
}
