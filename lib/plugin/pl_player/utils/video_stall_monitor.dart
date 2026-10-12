import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Logcat tag: `adb logcat -s PiliVideoStall flutter`
const String kVideoStallLogTag = 'PiliVideoStall';

const String kVideoStallLogFileName = 'pili_video_stall.log';

/// Cheap 1 Hz poll is enough to catch "picture frozen, audio continues".
const Duration kVideoStallPollInterval = Duration(seconds: 1);

/// Consecutive stuck polls before we call it a stall (~3s at 1 Hz).
const int kVideoStallTickThreshold = 3;

const int kVideoStallMaxRecoveries = 2;

const Duration kVideoStallRecoveryCooldown = Duration(seconds: 5);

const double kVideoStallPtsEpsilon = 0.05;

/// mpv `estimated-vf-fps` below this while the clock is moving counts as
/// "no video frames flowing". 1.0 is well under any real container fps.
const double kVideoStallVfFpsFloor = 1.0;

/// Heartbeat every N watch polls so a freeze window is visible even if STALL
/// does not fire. 5s at 1 Hz.
const int kVideoStallHeartbeatEvery = 5;

/// Decoder/NAL errors in one poll interval that count as a frozen tick.
const int kVideoStallDecoderFaultThreshold = 8;

/// Keep a NAL/decode burst "hot" for this many later polls. The 18:02:48
/// storm lasted <100ms, so a 1 Hz snapshot otherwise sees decoderFaults=0
/// on the next TICK and resets stuckTicks.
const int kVideoStallDecoderFaultStickyTicks = 3;

/// Don't treat video EOF as a stall when we are this close to duration.
const double kVideoStallNearEndSec = 2.0;

enum VideoStallRecoveryAction {
  /// Flush the decoder by seeking to the current position.
  seekFlush,

  /// Switch zero-copy MediaCodec to copy-back, then seek to reinit.
  switchToCopyHwdec,

  /// Re-open the current media at the current position (same URL).
  reopen,

  /// Re-open with a different CDN host (same path/query).
  reopenFreshUrl,
}

enum VideoStallReason {
  videoPtsFrozen,
  vfFpsCollapsed,
  decoderFaults,
  videoEof,
  framesStopped,
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
    this.decoderFrameDropCount,
    this.containerFps,
    this.cacheUsed = '',
    this.demuxerCacheDuration = '',
    this.bufferedSec = 0,
    this.playerReused = false,
    this.mediaPath = '',
    this.appScene = 'foreground',
    this.avsync = '',
    this.videoBitrate = '',
    this.decoderFaultCount = 0,
    this.autoRecover = true,
    this.verboseLog = true,
    this.estimatedFrameNumber,
    this.durationSec,
    this.videoEof = false,
    this.faultWindow = 0,
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
  final int? decoderFrameDropCount;
  final double? containerFps;
  final String cacheUsed;
  final String demuxerCacheDuration;
  final int bufferedSec;
  final bool playerReused;
  final String mediaPath;
  final String appScene;
  final String avsync;
  final String videoBitrate;
  final int decoderFaultCount;
  final bool autoRecover;
  final bool verboseLog;
  final int? estimatedFrameNumber;
  final double? durationSec;
  final bool videoEof;
  final int faultWindow;

  bool get nearEnd {
    final pos = timePos;
    final dur = durationSec;
    if (pos == null || dur == null || dur <= 1) return false;
    return dur - pos <= kVideoStallNearEndSec;
  }

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

  /// A sample we can actually use: mpv `video-pts` is often unavailable with
  /// `vo=gpu` + mediacodec-copy, so arm on estimated filter fps instead.
  bool get isArmed =>
      videoPts != null ||
      (estimatedVfFps != null && estimatedVfFps! >= kVideoStallVfFpsFloor);

  bool get vfFpsCollapsed =>
      estimatedVfFps != null && estimatedVfFps! < kVideoStallVfFpsFloor;

  bool get decoderUnhappy =>
      decoderFaultCount >= kVideoStallDecoderFaultThreshold;

  String get codecFamily {
    final raw = '${videoCodec.toLowerCase()} ${videoFormat.toLowerCase()}';
    if (raw.contains('av1') || raw.contains('av01')) return 'av1';
    if (raw.contains('hevc') ||
        raw.contains('h265') ||
        raw.contains('hev1') ||
        raw.contains('hvc1')) {
      return 'hevc';
    }
    if (raw.contains('avc') || raw.contains('h264')) return 'avc';
    return videoFormat.isEmpty ? '-' : videoFormat;
  }

  String toLogLine() {
    final size = (width != null && height != null) ? '${width}x$height' : '-';
    final path = mediaPath.length > 160
        ? '${mediaPath.substring(0, 160)}…'
        : mediaPath;
    return 'playing=$playing status=${playerStatus.name} '
        'buffering=$isBuffering seeking=$isSeeking audioOnly=$onlyPlayAudio '
        'live=$isLive scene=$appScene reusedPlayer=$playerReused '
        'armed=$isArmed autoRecover=$autoRecover verbose=$verboseLog '
        'timePos=${_fmt(timePos)} videoPts=${_fmt(videoPts)} '
        'audioPts=${_fmt(audioPts)} fps=${_fmt(containerFps)} '
        'vfFps=${_fmt(estimatedVfFps)} avsync=$avsync '
        'frameDrop=$dropFrameCount decoderDrop=$decoderFrameDropCount '
        'voDrop=$voDropFrameCount delayed=$voDelayedFrameCount '
        'decoderFaults=$decoderFaultCount faultWindow=$faultWindow '
        'videoEof=$videoEof frameNo=$estimatedFrameNumber '
        'duration=${_fmt(durationSec)} bitrate=$videoBitrate '
        'hwdecRequested=$hwdec hwdecCurrent=$hwdecCurrent vo=$vo '
        'codec=$codecFamily format=$videoFormat '
        'vcodec=$videoCodec acodec=$audioCodec vid=$vid '
        'pausedForCache=$pausedForCache coreIdle=$coreIdle '
        'cacheUsed=$cacheUsed demuxerCache=$demuxerCacheDuration '
        'bufferedSec=$bufferedSec '
        'speed=${_fmt(speed)} videoSync=$videoSync textureId=$textureId size=$size '
        'path=$path';
  }

  static String _fmt(double? value) =>
      value == null ? '-' : value.toStringAsFixed(3);
}

@immutable
class VideoStallObserveResult {
  const VideoStallObserveResult({
    this.logStart = false,
    this.logTick = false,
    this.logPause = false,
    this.isStalled = false,
    this.recovery,
    this.reasons = const [],
  });

  final bool logStart;
  final bool logTick;
  final bool logPause;
  final bool isStalled;
  final VideoStallRecoveryAction? recovery;
  final List<VideoStallReason> reasons;
}

/// Detects video renderer stall (picture frozen) while the audio/playback
/// clock keeps advancing. Extracted so the decision logic is unit-testable
/// without a live mpv instance.
///
/// Samsung S26 Ultra (2026-10-12 capture): every START line had `videoPts=-`
/// because libmpv `video-pts` stayed unavailable, so the old detector never
/// incremented stuck ticks. Fall back to `estimated-vf-fps` collapsing while
/// the audio/time-pos clock still moves, after the stream has armed.
class VideoStallMonitor {
  VideoStallMonitor({this.now});

  /// Optional clock override for tests.
  final DateTime Function()? now;

  int stuckTicks = 0;
  int recoveries = 0;
  VideoStallSnapshot? previous;
  bool loggedStart = false;
  DateTime? lastRecoveryAt;
  int watchTicks = 0;
  int pendingDecoderFaults = 0;
  bool everArmed = false;
  int decoderFaultWindow = 0;
  bool videoEofSticky = false;

  void resetForNewMedia() {
    stuckTicks = 0;
    recoveries = 0;
    previous = null;
    loggedStart = false;
    lastRecoveryAt = null;
    watchTicks = 0;
    pendingDecoderFaults = 0;
    everArmed = false;
    decoderFaultWindow = 0;
    videoEofSticky = false;
  }

  /// After a recovery attempt, drop the current freeze signals so the next
  /// media open is not immediately treated as still stalled.
  void clearAfterRecovery() {
    stuckTicks = 0;
    previous = null;
    pendingDecoderFaults = 0;
    decoderFaultWindow = 0;
    videoEofSticky = false;
  }

  void noteDecoderFault() {
    pendingDecoderFaults++;
  }

  void noteVideoEof() {
    videoEofSticky = true;
  }

  int takeDecoderFaults() {
    final n = pendingDecoderFaults;
    pendingDecoderFaults = 0;
    return n;
  }

  VideoStallObserveResult observe(VideoStallSnapshot snap) {
    final prev = previous;
    final logPause = prev != null && prev.shouldWatch && !snap.shouldWatch;
    if (snap.shouldWatch && snap.isArmed) {
      everArmed = true;
    }
    final resultLogStart = !loggedStart && snap.shouldWatch && snap.isArmed;
    if (resultLogStart) {
      loggedStart = true;
    }

    var logTick = false;
    if (snap.shouldWatch) {
      watchTicks++;
      logTick = watchTicks % kVideoStallHeartbeatEvery == 0;
    }

    if (!snap.shouldWatch) {
      stuckTicks = 0;
      previous = snap;
      return VideoStallObserveResult(
        logStart: resultLogStart,
        logTick: logTick,
        logPause: logPause,
      );
    }

    previous = snap;
    if (prev == null || !prev.shouldWatch) {
      return VideoStallObserveResult(
        logStart: resultLogStart,
        logTick: logTick,
        logPause: logPause,
      );
    }

    final clockAdvanced = _advanced(prev.clockPts, snap.clockPts);
    final videoAdvanced = _advanced(prev.videoPts, snap.videoPts);
    // Seek/loop can jump PTS backwards; treat that as a reset, not a stall.
    if (_jumpedBack(prev.clockPts, snap.clockPts) ||
        _jumpedBack(prev.videoPts, snap.videoPts)) {
      stuckTicks = 0;
      return VideoStallObserveResult(
        logStart: resultLogStart,
        logTick: logTick,
        logPause: logPause,
      );
    }

    final reasons = <VideoStallReason>[];
    if (snap.videoPts != null && clockAdvanced && !videoAdvanced) {
      reasons.add(VideoStallReason.videoPtsFrozen);
    }
    // Only use vf-fps after we have seen frames flowing. Otherwise startup
    // (vfFps still 0 / unset) would look like a freeze. Keep using everArmed
    // so a collapsed snapshot (vfFps=0 → isArmed=false) still counts.
    if (everArmed &&
        snap.vfFpsCollapsed &&
        clockAdvanced &&
        snap.videoPts == null) {
      reasons.add(VideoStallReason.vfFpsCollapsed);
    }
    // A NAL/decode burst is usually <100ms. takeDecoderFaults() zeros the
    // count every 1 Hz poll, so keep the burst hot for a few later ticks.
    if (snap.decoderFaultCount >= kVideoStallDecoderFaultThreshold) {
      decoderFaultWindow = kVideoStallDecoderFaultStickyTicks;
    }
    if ((snap.decoderUnhappy || decoderFaultWindow > 0) && clockAdvanced) {
      reasons.add(VideoStallReason.decoderFaults);
    }
    if (decoderFaultWindow > 0) {
      decoderFaultWindow--;
    }
    // Video track died (EOF/error) while audio/time-pos still moves, and
    // we are not at the real end of the file.
    if ((videoEofSticky || snap.videoEof) && clockAdvanced && !snap.nearEnd) {
      reasons.add(VideoStallReason.videoEof);
    }
    // Prefer a presented-frame counter. estimated-frame-number may track
    // time-pos (container fps) and then never fire — that is OK.
    if (everArmed &&
        clockAdvanced &&
        prev.estimatedFrameNumber != null &&
        snap.estimatedFrameNumber != null &&
        prev.estimatedFrameNumber! > 0 &&
        snap.estimatedFrameNumber == prev.estimatedFrameNumber) {
      reasons.add(VideoStallReason.framesStopped);
    }

    if (reasons.isNotEmpty) {
      stuckTicks++;
    } else {
      stuckTicks = 0;
    }

    if (stuckTicks < kVideoStallTickThreshold) {
      return VideoStallObserveResult(
        logStart: resultLogStart,
        logTick: logTick,
        logPause: logPause,
      );
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
      action = pickRecoveryAction(snap, recoveries, reasons);
    }

    return VideoStallObserveResult(
      logStart: resultLogStart,
      logTick: logTick,
      logPause: logPause,
      isStalled: true,
      recovery: action,
      reasons: reasons,
    );
  }

  static VideoStallRecoveryAction pickRecoveryAction(
    VideoStallSnapshot snap,
    int recoveryNumber, [
    List<VideoStallReason> reasons = const [],
  ]) {
    if (snap.isLive) {
      return VideoStallRecoveryAction.reopen;
    }
    // Seeking a demuxer that already lost NAL sync produced the bogus
    // 923MB "stream level seek" in the 18:02 capture. Reopen instead.
    final streamDied = reasons.any(_isStreamDeathReason);
    if (streamDied) {
      return recoveryNumber <= 1
          ? VideoStallRecoveryAction.reopenFreshUrl
          : VideoStallRecoveryAction.reopen;
    }
    if (recoveryNumber <= 1) {
      return VideoStallRecoveryAction.seekFlush;
    }
    if (HwDecType.isDirectMediacodec(snap.hwdecCurrent)) {
      return VideoStallRecoveryAction.switchToCopyHwdec;
    }
    return VideoStallRecoveryAction.reopen;
  }

  static bool _isStreamDeathReason(VideoStallReason reason) {
    return reason == VideoStallReason.videoEof ||
        reason == VideoStallReason.decoderFaults ||
        reason == VideoStallReason.framesStopped;
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
  static final List<String> _pending = [];
  static bool _flushing = false;

  static void start(VideoStallSnapshot snap) =>
      _log('START ${snap.toLogLine()}');

  static void tick(VideoStallSnapshot snap) => _log('TICK ${snap.toLogLine()}');

  static void pause(VideoStallSnapshot snap) =>
      _log('PAUSE ${snap.toLogLine()}');

  static void stall(
    VideoStallSnapshot snap, {
    required int recoveries,
    List<VideoStallReason> reasons = const [],
  }) => _log(
    'STALL recoveries=$recoveries reason=${reasons.map((e) => e.name).join(",")}'
    ' ${snap.toLogLine()}',
  );

  static void recovery(
    VideoStallRecoveryAction action,
    VideoStallSnapshot snap,
  ) => _log('RECOVERY action=${action.name} ${snap.toLogLine()}');

  static void recoverySkipped(VideoStallSnapshot snap) =>
      _log('STALL_NO_RECOVERY autoRecover=off ${snap.toLogLine()}');

  static void hwdecFallback(String detail) => _log('HWDEC_FALLBACK $detail');

  static void cdnRotate({required String from, required String to}) =>
      _log('CDN_ROTATE from=$from to=$to');

  static void proxy(String message) => _log('PROXY $message');

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
    _pending.add('${DateTime.now().toIso8601String()} $message');
    unawaited(_flush());
  }

  static Future<File> logFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, kVideoStallLogFileName));
  }

  static Future<String> readExportText() async {
    try {
      await _flush();
      final file = await logFile();
      if (!file.existsSync()) {
        return '[$kVideoStallLogTag] no freeze log yet';
      }
      return file.readAsStringSync();
    } catch (e) {
      return '[$kVideoStallLogTag] read failed: $e';
    }
  }

  static Future<void> clearFile() async {
    try {
      _pending.clear();
      final file = await logFile();
      if (file.existsSync()) {
        await file.writeAsString('', flush: true);
      }
    } catch (_) {}
  }

  static Future<void> _flush() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    try {
      final file = await logFile();
      final chunk = '${_pending.join('\n')}\n';
      _pending.clear();
      await file.writeAsString(chunk, mode: FileMode.append, flush: true);
    } catch (_) {
      // Tests / missing path_provider must not crash playback.
    } finally {
      _flushing = false;
      if (_pending.isNotEmpty) {
        unawaited(_flush());
      }
    }
  }
}
