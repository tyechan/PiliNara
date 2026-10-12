import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/utils/video_stall_monitor.dart';
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
  String? _generation;

  bool get isRunning => _server != null && port != null;

  bool get hasActiveSession => _sessions.isNotEmpty;

  String? get preferredHost =>
      _sessions.isEmpty ? null : _sessions.values.first.pool.preferred?.host;

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
      VideoStallLog.proxy(
        'listen 127.0.0.1:$port threads=${Pref.vodMultiConnThreads} '
        'chunk=${Pref.vodMultiConnChunkKb}KB window=${Pref.vodMultiConnWindowMb}MB',
      );
      return true;
    } catch (e) {
      VideoStallLog.proxy('listen-failed $e');
      _server = null;
      port = null;
      return false;
    }
  }

  Future<NetworkSource?> wrap(NetworkSource source) async {
    if (source.videoSource.startsWith('edl://') ||
        source.videoSource.startsWith('http://127.0.0.1')) {
      return null;
    }
    if (!await ensureStarted()) return null;
    _dropStale(source.videoSource);
    final video = _open(
      kind: 'video',
      primary: source.videoSource,
      extras: source.videoCandidates,
    );
    String? audio;
    if (source.audioSource case final a? when a.isNotEmpty) {
      audio = _open(kind: 'audio', primary: a, extras: source.audioCandidates);
    }
    VideoStallLog.proxy(
      'wrap video=$video audio=${audio ?? '-'} '
      'srcHost=${Uri.tryParse(source.videoSource)?.host ?? '-'}',
    );
    return NetworkSource(
      videoSource: video,
      audioSource: audio,
      videoCandidates: source.videoCandidates,
      audioCandidates: source.audioCandidates,
    );
  }

  void _dropStale(String videoPrimary) {
    final gen = videoPrimary;
    if (_generation == gen) return;
    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
    _generation = gen;
  }

  String _open({
    required String kind,
    required String primary,
    required List<String> extras,
  }) {
    final id = '$kind${++_seq}';
    final candidates = VodHostPool.buildCandidates(primary, extras: extras);
    _sessions[id] = VodSession(
      id: id,
      kind: kind,
      candidates: candidates,
      chunkSize: Pref.vodMultiConnChunkKb * 1024,
      windowBytes: Pref.vodMultiConnWindowMb * 1024 * 1024,
      workers: Pref.vodMultiConnThreads.clamp(1, 16),
    );
    return 'http://127.0.0.1:$port/$id';
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
      final parsed = HttpRangeRequest.parse(
        request.headers.value(HttpHeaders.rangeHeader),
      );
      final range = (parsed ?? const HttpRangeRequest(start: 0)).resolve(size);
      if (range.length <= 0) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await response.close();
        return;
      }

      response.statusCode = HttpStatus.partialContent;
      response.headers.chunkedTransferEncoding = false;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.endInclusive}/$size',
      );
      response.headers.contentLength = range.length;
      response.bufferOutput = true;

      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      await for (final chunk in session.read(range.start, range.endExclusive)) {
        response.add(chunk);
        await response.flush();
      }
      await response.close();
    } catch (e) {
      try {
        if (response.headers.contentLength == -1 &&
            response.statusCode == HttpStatus.ok) {
          response.statusCode = HttpStatus.badGateway;
        }
        await response.close();
      } catch (_) {}
    }
  }
}
