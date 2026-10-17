import 'dart:async';

import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
import 'package:media_kit/media_kit.dart';

/// Lightweight playback diagnostics: mpv events, direct-mode cache stats,
/// and video-stuck / audio-advancing freeze evidence (log only).
class PlaybackDiag {
  PlaybackDiag();

  Timer? _tick;
  int _ticks = 0;
  DateTime? _bufferingSince;
  DateTime? _firstFrameAt;
  DateTime? _startedAt;
  bool _loggedFirstFrame = false;
  DateTime? _videoStuckSince;
  bool _freezeLogged = false;
  double? _lastVideoPts;
  double? _lastAudioPts;
  int? _lastFrame;
  int _nalBurst = 0;
  DateTime? _nalWindowStart;
  bool _eofVideo = false;
  bool _eofAudio = false;
  String? _lastHwdec;
  bool _directMode = true;
  String _videoHost = '-';
  String _audioHost = '-';
  String? _dashCodec;
  void Function(String reason)? onEarlyEnd;
  DateTime? _lastRecoverAt;
  int _recoverCount = 0;

  void attach(
    Player player, {
    required bool proxy,
    String? videoHost,
    String? audioHost,
    String? dashCodec,
  }) {
    detach();
    _directMode = !proxy;
    _videoHost = (videoHost == null || videoHost.isEmpty) ? '-' : videoHost;
    _audioHost = (audioHost == null || audioHost.isEmpty) ? '-' : audioHost;
    _dashCodec = dashCodec;
    _loggedFirstFrame = false;
    _firstFrameAt = null;
    _startedAt = DateTime.now();
    VodProxyLog.firstFrameMs = null;
    _videoStuckSince = null;
    _freezeLogged = false;
    _lastVideoPts = null;
    _lastAudioPts = null;
    _lastFrame = null;
    _nalBurst = 0;
    _eofVideo = false;
    _eofAudio = false;
    _recoverCount = 0;
    _lastRecoverAt = null;
    _ticks = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      _onTick(player);
    });
  }

  void detach() {
    _tick?.cancel();
    _tick = null;
    _bufferingSince = null;
  }

  void onBuffering(bool buffering) {
    if (buffering) {
      _bufferingSince ??= DateTime.now();
      VodProxyLog.play('mpv buffering-start');
    } else if (_bufferingSince != null) {
      final dur = DateTime.now().difference(_bufferingSince!).inMilliseconds;
      VodProxyLog.play('mpv buffering-end dur=${(dur / 1000).toStringAsFixed(2)}s');
      _bufferingSince = null;
    }
  }

  void onSeek(Duration pos) {
    _videoStuckSince = null;
    _freezeLogged = false;
    VodProxyLog.play('mpv seek pos=${pos.inMilliseconds}ms');
  }

  /// Video progress must not use mpv `time-pos` (it follows the audio clock).
  static bool freezeVideoMoved({
    required int? frame,
    required int? lastFrame,
    required double? videoPts,
    required double? lastVideoPts,
  }) {
    if (frame != null && lastFrame != null && frame > lastFrame) return true;
    if (videoPts != null &&
        lastVideoPts != null &&
        videoPts > lastVideoPts + 0.15) {
      return true;
    }
    return false;
  }

  static bool freezeAudioMoved({
    required double? audioPts,
    required double? lastAudioPts,
  }) {
    return audioPts != null &&
        lastAudioPts != null &&
        audioPts > lastAudioPts + 0.15;
  }

  void onLog(PlayerLog log) {
    final text = log.text;
    final lower = text.toLowerCase();
    if (text.contains('Invalid NAL unit size') ||
        text.contains('error while decoding MB')) {
      _noteNal();
      return;
    }
    if (text.contains('Stream ends prematurely') ||
        lower.contains('stream ends prematurely')) {
      VodProxyLog.play('mpv stream-ends-prematurely ${log.prefix}');
      _requestRecover('video-eof');
      return;
    }
    if (lower.contains('partial file')) {
      VodProxyLog.play('mpv partial-file ${log.prefix} ${log.text}');
      _requestRecover('partial-file');
      return;
    }
    if (lower.contains('reconnect') || text.contains('ffurl_read returned')) {
      VodProxyLog.play('mpv reconnect ${log.prefix} ${log.text}');
    }
  }

  void onError(String event) {
    final lower = event.toLowerCase();
    if (event.contains('Invalid NAL unit size')) {
      _noteNal();
      return;
    }
    if (lower.contains('partial file')) {
      VodProxyLog.play('mpv partial-file $event');
      _requestRecover('partial-file');
      return;
    }
    if (event.contains('EOF') || lower.contains('end of file')) {
      if (lower.contains('audio') && !_eofAudio) {
        _eofAudio = true;
        VodProxyLog.play('mpv eof audio');
      } else if (!_eofVideo) {
        _eofVideo = true;
        VodProxyLog.play('mpv eof video');
        _requestRecover('video-eof');
      }
    }
  }

  void _requestRecover(String reason) {
    if (_directMode) return;
    final now = DateTime.now();
    if (_recoverCount >= 2) return;
    if (_lastRecoverAt != null &&
        now.difference(_lastRecoverAt!) < const Duration(seconds: 8)) {
      return;
    }
    _recoverCount++;
    _lastRecoverAt = now;
    _eofVideo = false;
    _videoStuckSince = null;
    _freezeLogged = false;
    onEarlyEnd?.call(reason);
  }

  void _noteNal() {
    _nalWindowStart ??= DateTime.now();
    if (DateTime.now().difference(_nalWindowStart!) > const Duration(seconds: 5)) {
      if (_nalBurst > 0) {
        VodProxyLog.play(
          'mpv decoder-error Invalid NAL unit size n=$_nalBurst / 5s',
        );
      }
      _nalBurst = 0;
      _nalWindowStart = DateTime.now();
    }
    _nalBurst++;
    if (_nalBurst == 1 || _nalBurst == 8) {
      VodProxyLog.play(
        'mpv decoder-error Invalid NAL unit size n=$_nalBurst / 5s',
      );
    }
  }

  void _onTick(Player player) {
    String prop(String name) {
      try {
        return player.getProperty(name);
      } catch (_) {
        return '';
      }
    }

    try {
      _ticks++;
      if (!_loggedFirstFrame) {
        final frames = int.tryParse(prop('estimated-frame-count'));
        final timePos = player.state.position;
        if ((frames != null && frames > 0) || timePos > Duration.zero) {
          _loggedFirstFrame = true;
          _firstFrameAt = DateTime.now();
          VodProxyLog.firstFrameMs = _startedAt == null
              ? null
              : _firstFrameAt!.difference(_startedAt!).inMilliseconds;
          final hwdec = prop('hwdec-current');
          _lastHwdec = hwdec;
          var codec = prop('video-codec');
          if (codec.isEmpty) codec = prop('video-format');
          if (codec.isEmpty) codec = _dashCodec ?? '';
          final fps = prop('estimated-vf-fps');
          VodProxyLog.play(
            'mpv first-frame hwdec=$hwdec codec=$codec fps=$fps pos=${timePos.inMilliseconds}ms',
          );
          VodProxyLog.play('mpv hwdec=$hwdec');
        }
      }

      if (_directMode && (_ticks == 1 || _ticks % 5 == 0)) {
        VodProxyLog.play(
          'mpv cache cache-speed=${prop('cache-speed')} '
          'demuxer-cache-duration=${prop('demuxer-cache-duration')} '
          'paused-for-cache=${prop('paused-for-cache')} '
          'videoHost=$_videoHost audioHost=$_audioHost',
        );
      }

      final pausedForCache = prop('paused-for-cache');
      final seeking = prop('seeking');
      final paused = prop('pause');
      final eofReached = prop('eof-reached');
      final videoPts = double.tryParse(prop('video-pts'));
      final audioPts = double.tryParse(prop('audio-pts'));
      final frame = int.tryParse(prop('estimated-frame-number'));
      final timePos = player.state.position;
      final duration = player.state.duration;

      if (eofReached == 'yes' &&
          !_directMode &&
          duration > const Duration(seconds: 2) &&
          timePos + const Duration(seconds: 2) < duration) {
        _requestRecover('video-eof');
      }

      final buffering = pausedForCache == 'yes' || paused == 'yes' || seeking == 'yes';
      final videoMoved = freezeVideoMoved(
        frame: frame,
        lastFrame: _lastFrame,
        videoPts: videoPts,
        lastVideoPts: _lastVideoPts,
      );
      final audioMoved = freezeAudioMoved(
        audioPts: audioPts,
        lastAudioPts: _lastAudioPts,
      );
      if (!buffering && !videoMoved && audioMoved) {
        _videoStuckSince ??= DateTime.now();
        final stuck = DateTime.now().difference(_videoStuckSince!);
        if (!_freezeLogged && stuck >= const Duration(seconds: 3)) {
          _freezeLogged = true;
          final aAdv = audioPts != null && _lastAudioPts != null
              ? ((audioPts - _lastAudioPts!) * 1000).round()
              : -1;
          VodProxyLog.play(
            'freeze video-stuck=${stuck.inMilliseconds}ms '
            'audio-adv=${aAdv}ms '
            'vpos=${timePos.inMilliseconds}ms '
            'video-pts=${videoPts ?? '-'} audio-pts=${audioPts ?? '-'} '
            'frames=${frame ?? -1} hwdec=${_lastHwdec ?? prop('hwdec-current')} '
            'paused-for-cache=$pausedForCache eof-reached=$eofReached '
            'demuxer-cache-duration=${prop('demuxer-cache-duration')} '
            'cache-speed=${prop('cache-speed')} seeking=$seeking pause=$paused',
          );
        }
      } else if (videoMoved) {
        _videoStuckSince = null;
        _freezeLogged = false;
      }
      _lastVideoPts = videoPts ?? _lastVideoPts;
      _lastAudioPts = audioPts ?? _lastAudioPts;
      if (frame != null) _lastFrame = frame;
    } catch (_) {}
  }
}
