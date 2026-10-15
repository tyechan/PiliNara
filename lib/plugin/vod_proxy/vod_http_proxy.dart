import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
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
  int _seq = 0;
  bool _forceDirectOnce = false;
  DateTime? lastRequestAt;
  int requestsServed = 0;

  bool get isRunning => _server != null && port != null;

  bool get hasActiveSession => _sessions.isNotEmpty;

  Iterable<VodSession> get debugSessions => _sessions.values;

  void forceDirectOnce() {
    _forceDirectOnce = true;
  }

  void closeAll({String reason = 'close'}) {
    if (_sessions.isEmpty) return;
    VodProxyLog.log('close reason=$reason n=${_sessions.length}');
    for (final session in _sessions.values) {
      session.close(reason: reason);
    }
    _sessions.clear();
  }

  Future<void> resetForTest() async {
    VodProxyLog.resetForTest();
    closeAll(reason: 'reset-test');
    _seq = 0;
    _forceDirectOnce = false;
    requestsServed = 0;
    lastRequestAt = null;
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
      final hosts = session.pool.topHosts(k: 3).map((h) => h.host).join(',');
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

  Future<NetworkSource?> wrap(NetworkSource source) async {
    if (_forceDirectOnce) {
      _forceDirectOnce = false;
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
    try {
      await _sessions[videoId]!.ensureSize();
    } catch (e) {
      VodProxyLog.log('probe-failed video $e — using direct URL');
      _sessions[videoId]?.fallbackReason = e.toString();
      _sessions[videoId]?.close(reason: 'probe-failed');
      _sessions.remove(videoId);
      return null;
    }
    String? audio;
    if (source.audioSource case final a? when a.isNotEmpty) {
      final audioId = _register(
        kind: 'audio',
        primary: a,
        extras: source.audioCandidates,
      );
      try {
        await _sessions[audioId]!.ensureSize();
        audio = _url(audioId);
      } catch (e) {
        VodProxyLog.log('probe-failed audio $e — using direct audio');
        _sessions[audioId]?.fallbackReason = e.toString();
        _sessions[audioId]?.close(reason: 'probe-failed');
        _sessions.remove(audioId);
        audio = a;
      }
    }
    final video = _url(videoId);
    final vHosts = _sessions[videoId]?.pool.topHosts(k: 3).map((h) => h.host).join(',') ?? '-';
    final aId = audio != null && audio.startsWith('http://127.0.0.1')
        ? audio.split('/').last
        : null;
    final aHosts = aId == null
        ? '-'
        : (_sessions[aId]?.pool.topHosts(k: 3).map((h) => h.host).join(',') ?? '-');
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
  }) async {
    if (!await ensureStarted()) return null;
    final id = _register(
      kind: kind,
      primary: primary,
      extras: const [],
      chunkSize: chunkSize,
      windowBytes: windowBytes,
      workers: workers,
      attemptTimeout: attemptTimeout,
      fetchBudget: fetchBudget,
    );
    try {
      await _sessions[id]!.ensureSize();
    } catch (e) {
      VodProxyLog.log('openRaw-probe-failed $e');
      _sessions[id]?.close(reason: 'probe-failed');
      _sessions.remove(id);
      return null;
    }
    return _url(id);
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
  }) {
    final id = '$kind${++_seq}';
    final candidates = VodHostPool.buildCandidates(primary, extras: extras);
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

    _sessions[id] = VodSession(
      id: id,
      kind: kind,
      candidates: candidates.isEmpty ? [primary] : candidates,
      chunkSize: chunkSize ?? fallbackChunk(),
      windowBytes: windowBytes ?? fallbackWindow(),
      workers: workers ?? fallbackWorkers(),
      attemptTimeout: attemptTimeout ?? const Duration(seconds: 6),
      fetchBudget: fetchBudget ?? const Duration(seconds: 45),
    );
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
      final session = _sessions[id];
      if (session == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
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
