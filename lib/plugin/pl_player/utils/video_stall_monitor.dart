import 'dart:developer' as developer;

import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:flutter/foundation.dart';

/// Logcat tag: `adb logcat -s PiliVideoStall flutter`
const String kVideoStallLogTag = 'PiliVideoStall';

/// Cheap 1 Hz poll is enough to catch "picture frozen, audio continues".
const Duration kVideoStallPollInterval = Duration(seconds: 1);

/// Consecutive stuck polls before we call it a stall (~3s at 1 Hz).
const int kVideoStallTickThreshold = 3;

const int kVideoStallMaxRecoveries = 2;

const Duration kVideoStallRecoveryCooldown = Duration(seconds: 5);

const double kVideoStallPtsEpsilon = 0.05;

enum VideoStallRecoveryAction {
  /// Flush the decoder by seeking to the current position.
  seekFlush,

  /// Switch zero-copy MediaCodec to copy-back, then seek to reinit.
  switchToCopyHwdec,

  /// Re-open the current media (live or last-resort VOD).
  reopen,
}

@immutable
class VideoStallSnapshot {
  const VideoStallSnapshot({
    required this.playerStatus,
    required this.playing,
    required this.isBuffering,
    required this.isSeeking,
    required this.onlyPlayAudio,
    required this.isLive,
    required this.timePos,
    required this.videoPts,
    required this.audioPts,
    required this.estimatedVfFps,
    required this.dropFrameCount,
    required this.voDropFrameCount,
    required this.voDelayedFrameCount,
    required this.hwdec,
    required this.hwdecCurrent,
    required this.vo,
    required this.videoFormat,
    required this.videoCodec,
    required this.audioCodec,
    required this.vid,
    required this.pausedForCache,
    required this.coreIdle,
    required this.speed,
    required this.videoSync,
    required this.textureId,
    required this.width,
    required this.height,
  });

  final PlayerStatus playerStatus;
  final bool playing;
  final bool isBuffering;
  final bool isSeeking;
  final bool onlyPlayAudio;
  final bool isLive;
  final double? timePos;
  final double? videoPts;
  final double? audioPts;
  final double? estimatedVfFps;
  final int? dropFrameCount;
  final int? voDropFrameCount;
  final int? voDelayedFrameCount;
  final String hwdec;
  final String hwdecCurrent;
  final String vo;
  final String videoFormat;
  final String videoCodec;
  final String audioCodec;
  final String vid;
  final String pausedForCache;
  final String coreIdle;
  final double? speed;
  final String videoSync;
  final int? textureId;
  final int? width;
  final int? height;

  /// Audio/playback clock: prefer audio PTS, fall back to time-pos.
  double? get clockPts => audioPts ?? timePos;

  bool get hasVideoTrack =>
      !onlyPlayAudio && vid.isNotEmpty && vid != 'no' && vid != 'false';

  bool get shouldWatch =>
      playing &&
      playerStatus.isPlaying &&
      !isBuffering &&
      !isSeeking &&
      hasVideoTrack &&
      pausedForCache != 'yes' &&
      pausedForCache != 'true';

  String toLogLine() {
    final size = (width != null && height != null) ? '${width}x$height' : '-';
    return 'playing=$playing status=${playerStatus.name} '
        'buffering=$isBuffering seeking=$isSeeking audioOnly=$onlyPlayAudio '
        'live=$isLive timePos=${_fmt(timePos)} videoPts=${_fmt(videoPts)} '
        'audioPts=${_fmt(audioPts)} vfFps=${_fmt(estimatedVfFps)} '
        'drop=$dropFrameCount voDrop=$voDropFrameCount delayed=$voDelayedFrameCount '
        'hwdec=$hwdec hwdecCurrent=$hwdecCurrent vo=$vo format=$videoFormat '
        'vcodec=$videoCodec acodec=$audioCodec vid=$vid '
        'pausedForCache=$pausedForCache coreIdle=$coreIdle '
        'speed=${_fmt(speed)} videoSync=$videoSync textureId=$textureId size=$size';
  }

  static String _fmt(double? value) =>
      value == null ? '-' : value.toStringAsFixed(3);
}

@immutable
class VideoStallObserveResult {
  const VideoStallObserveResult({
    this.logStart = false,
    this.isStalled = false,
    this.recovery,
  });

  final bool logStart;
  final bool isStalled;
  final VideoStallRecoveryAction? recovery;
}

/// Detects video renderer stall (picture frozen) while the audio/playback
/// clock keeps advancing. Extracted so the decision logic is unit-testable
/// without a live mpv instance.
class VideoStallMonitor {
  VideoStallMonitor({this.now});

  /// Optional clock override for tests.
  final DateTime Function()? now;

  int stuckTicks = 0;
  int recoveries = 0;
  VideoStallSnapshot? previous;
  bool loggedStart = false;
  DateTime? lastRecoveryAt;

  void resetForNewMedia() {
    stuckTicks = 0;
    recoveries = 0;
    previous = null;
    loggedStart = false;
    lastRecoveryAt = null;
  }

  VideoStallObserveResult observe(VideoStallSnapshot snap) {
    final resultLogStart = !loggedStart && snap.shouldWatch;
    if (resultLogStart) {
      loggedStart = true;
    }

    if (!snap.shouldWatch) {
      stuckTicks = 0;
      previous = snap;
      return VideoStallObserveResult(logStart: resultLogStart);
    }

    final prev = previous;
    previous = snap;
    if (prev == null || !prev.shouldWatch) {
      return VideoStallObserveResult(logStart: resultLogStart);
    }

    final clockAdvanced = _advanced(prev.clockPts, snap.clockPts);
    final videoAdvanced = _advanced(prev.videoPts, snap.videoPts);
    // Seek/loop can jump PTS backwards; treat that as a reset, not a stall.
    if (_jumpedBack(prev.clockPts, snap.clockPts) ||
        _jumpedBack(prev.videoPts, snap.videoPts)) {
      stuckTicks = 0;
      return VideoStallObserveResult(logStart: resultLogStart);
    }

    // Require a real video PTS sample so missing properties don't false-positive.
    final canDetect = snap.videoPts != null && snap.clockPts != null;
    if (canDetect && clockAdvanced && !videoAdvanced) {
      stuckTicks++;
    } else {
      stuckTicks = 0;
    }

    if (stuckTicks < kVideoStallTickThreshold) {
      return VideoStallObserveResult(logStart: resultLogStart);
    }

    VideoStallRecoveryAction? action;
    final timestamp = now?.call() ?? DateTime.now();
    final coolingDown =
        lastRecoveryAt != null &&
        timestamp.difference(lastRecoveryAt!) < kVideoStallRecoveryCooldown;
    if (!coolingDown && recoveries < kVideoStallMaxRecoveries) {
      recoveries++;
      lastRecoveryAt = timestamp;
      stuckTicks = 0;
      action = pickRecoveryAction(snap, recoveries);
    }

    return VideoStallObserveResult(
      logStart: resultLogStart,
      isStalled: true,
      recovery: action,
    );
  }

  static VideoStallRecoveryAction pickRecoveryAction(
    VideoStallSnapshot snap,
    int recoveryNumber,
  ) {
    if (snap.isLive) {
      return VideoStallRecoveryAction.reopen;
    }
    if (recoveryNumber <= 1) {
      return VideoStallRecoveryAction.seekFlush;
    }
    if (HwDecType.isDirectMediacodec(snap.hwdecCurrent)) {
      return VideoStallRecoveryAction.switchToCopyHwdec;
    }
    return VideoStallRecoveryAction.reopen;
  }

  static bool _advanced(double? prev, double? curr) {
    if (prev == null || curr == null) return false;
    return curr - prev > kVideoStallPtsEpsilon;
  }

  static bool _jumpedBack(double? prev, double? curr) {
    if (prev == null || curr == null) return false;
    return prev - curr > 1.0;
  }
}

abstract final class VideoStallLog {
  static void start(VideoStallSnapshot snap) =>
      _log('START ${snap.toLogLine()}');

  static void stall(VideoStallSnapshot snap, {required int recoveries}) =>
      _log('STALL recoveries=$recoveries ${snap.toLogLine()}');

  static void recovery(
    VideoStallRecoveryAction action,
    VideoStallSnapshot snap,
  ) => _log('RECOVERY action=${action.name} ${snap.toLogLine()}');

  static void surface({required int? from, required int? to}) {
    final kind = to == null ? 'SURFACE_INVALID' : 'SURFACE';
    _log('$kind textureId $from -> $to');
  }

  static void mpv({
    required String level,
    required String prefix,
    required String text,
  }) => _log('MPV $level $prefix: $text');

  static void _log(String message) {
    developer.log(message, name: kVideoStallLogTag);
    debugPrint('[$kVideoStallLogTag] $message');
  }
}
