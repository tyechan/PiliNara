import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/video_stall_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

VideoStallSnapshot _snap({
  PlayerStatus status = PlayerStatus.playing,
  bool playing = true,
  bool buffering = false,
  bool seeking = false,
  bool audioOnly = false,
  bool live = false,
  double? timePos = 10,
  double? videoPts = 10,
  double? audioPts = 10,
  String hwdecCurrent = 'mediacodec',
  String vid = '1',
  String pausedForCache = 'no',
}) {
  return VideoStallSnapshot(
    playerStatus: status,
    playing: playing,
    isBuffering: buffering,
    isSeeking: seeking,
    onlyPlayAudio: audioOnly,
    isLive: live,
    timePos: timePos,
    videoPts: videoPts,
    audioPts: audioPts,
    estimatedVfFps: 30,
    dropFrameCount: 0,
    voDropFrameCount: 0,
    voDelayedFrameCount: 0,
    hwdec: 'mediacodec,auto-safe',
    hwdecCurrent: hwdecCurrent,
    vo: 'gpu',
    videoFormat: 'h264',
    videoCodec: 'h264',
    audioCodec: 'aac',
    vid: vid,
    pausedForCache: pausedForCache,
    coreIdle: 'no',
    speed: 1,
    videoSync: 'display-resample',
    textureId: 7,
    width: 1920,
    height: 1080,
  );
}

void main() {
  test('does not flag healthy playback', () {
    final monitor = VideoStallMonitor();
    for (var i = 0; i < 6; i++) {
      final t = 10.0 + i;
      final result = monitor.observe(
        _snap(timePos: t, videoPts: t, audioPts: t),
      );
      expect(result.isStalled, isFalse, reason: 'tick $i');
      expect(result.recovery, isNull);
    }
  });

  test('flags stall when audio clock advances but video PTS does not', () {
    final monitor = VideoStallMonitor(now: () => DateTime(2026, 9, 21));
    monitor.observe(_snap(timePos: 10, videoPts: 10, audioPts: 10));

    VideoStallObserveResult? last;
    for (var i = 1; i <= kVideoStallTickThreshold; i++) {
      last = monitor.observe(
        _snap(timePos: 10.0 + i, videoPts: 10, audioPts: 10.0 + i),
      );
    }

    expect(last!.isStalled, isTrue);
    expect(last.recovery, VideoStallRecoveryAction.seekFlush);
    expect(monitor.recoveries, 1);
  });

  test('second recovery on direct mediacodec switches to copy-back', () {
    var t = DateTime(2026, 9, 21);
    final monitor = VideoStallMonitor(now: () => t);

    void stallOnce() {
      monitor.stuckTicks = 0;
      monitor.previous = _snap(timePos: 20, videoPts: 20, audioPts: 20);
      VideoStallObserveResult? last;
      for (var i = 1; i <= kVideoStallTickThreshold; i++) {
        last = monitor.observe(
          _snap(timePos: 20.0 + i, videoPts: 20, audioPts: 20.0 + i),
        );
      }
      expect(last!.isStalled, isTrue);
    }

    stallOnce();
    expect(monitor.recoveries, 1);

    t = t.add(kVideoStallRecoveryCooldown);
    VideoStallObserveResult? second;
    monitor.stuckTicks = 0;
    monitor.previous = _snap(timePos: 20, videoPts: 20, audioPts: 20);
    for (var i = 1; i <= kVideoStallTickThreshold; i++) {
      second = monitor.observe(
        _snap(timePos: 20.0 + i, videoPts: 20, audioPts: 20.0 + i),
      );
    }
    expect(second!.isStalled, isTrue);
    expect(second.recovery, VideoStallRecoveryAction.switchToCopyHwdec);
    expect(monitor.recoveries, 2);
  });

  test('already copy-back uses reopen on later recoveries', () {
    expect(
      VideoStallMonitor.pickRecoveryAction(
        _snap(hwdecCurrent: 'mediacodec-copy'),
        2,
      ),
      VideoStallRecoveryAction.reopen,
    );
  });

  test('cooldown skips a second recovery', () {
    final t = DateTime(2026, 9, 21);
    final monitor = VideoStallMonitor(now: () => t);
    monitor.observe(_snap(timePos: 10, videoPts: 10, audioPts: 10));
    VideoStallObserveResult? last;
    for (var i = 1; i <= kVideoStallTickThreshold; i++) {
      last = monitor.observe(
        _snap(timePos: 10.0 + i, videoPts: 10, audioPts: 10.0 + i),
      );
    }
    expect(last!.recovery, isNotNull);

    last = null;
    for (var i = 1; i <= kVideoStallTickThreshold; i++) {
      last = monitor.observe(
        _snap(timePos: 20.0 + i, videoPts: 10, audioPts: 20.0 + i),
      );
    }
    expect(last!.isStalled, isTrue);
    expect(last.recovery, isNull);
    expect(monitor.recoveries, 1);
  });

  test('live stall recovers by reopening, not seeking', () {
    expect(
      VideoStallMonitor.pickRecoveryAction(_snap(live: true), 1),
      VideoStallRecoveryAction.reopen,
    );
  });

  test('ignores pause, buffering, seek, and audio-only', () {
    final monitor = VideoStallMonitor();
    monitor.observe(_snap(timePos: 10, videoPts: 10, audioPts: 10));

    final paused = monitor.observe(
      _snap(
        status: PlayerStatus.paused,
        playing: false,
        timePos: 20,
        videoPts: 10,
        audioPts: 20,
      ),
    );
    expect(paused.isStalled, isFalse);

    final buffering = monitor.observe(
      _snap(buffering: true, timePos: 30, videoPts: 10, audioPts: 30),
    );
    expect(buffering.isStalled, isFalse);

    final seeking = monitor.observe(
      _snap(seeking: true, timePos: 40, videoPts: 10, audioPts: 40),
    );
    expect(seeking.isStalled, isFalse);

    final audioOnly = monitor.observe(
      _snap(
        audioOnly: true,
        vid: 'no',
        timePos: 50,
        videoPts: 10,
        audioPts: 50,
      ),
    );
    expect(audioOnly.isStalled, isFalse);
  });

  test('does not false-positive when video-pts is unavailable', () {
    final monitor = VideoStallMonitor();
    for (var i = 0; i < 6; i++) {
      final result = monitor.observe(
        _snap(timePos: 10.0 + i, videoPts: null, audioPts: 10.0 + i),
      );
      expect(result.isStalled, isFalse);
    }
  });

  test('resetForNewMedia clears recovery budget', () {
    final monitor = VideoStallMonitor(now: () => DateTime(2026, 9, 21));
    monitor.observe(_snap(timePos: 10, videoPts: 10, audioPts: 10));
    for (var i = 1; i <= kVideoStallTickThreshold; i++) {
      monitor.observe(
        _snap(timePos: 10.0 + i, videoPts: 10, audioPts: 10.0 + i),
      );
    }
    expect(monitor.recoveries, 1);

    monitor.resetForNewMedia();
    expect(monitor.recoveries, 0);
    expect(monitor.stuckTicks, 0);
    expect(monitor.previous, isNull);
  });

  test('logs START on first actively playing sample', () {
    final monitor = VideoStallMonitor();
    final idle = monitor.observe(
      _snap(status: PlayerStatus.paused, playing: false),
    );
    expect(idle.logStart, isFalse);

    final playing = monitor.observe(_snap());
    expect(playing.logStart, isTrue);

    final again = monitor.observe(
      _snap(timePos: 11, videoPts: 11, audioPts: 11),
    );
    expect(again.logStart, isFalse);
  });

  test('codecFamily maps avc/hevc/av1 from codec or format', () {
    expect(_snap().codecFamily, 'avc');
    expect(
      VideoStallSnapshot(
        playerStatus: PlayerStatus.playing,
        playing: true,
        isBuffering: false,
        isSeeking: false,
        onlyPlayAudio: false,
        isLive: false,
        timePos: 1,
        videoPts: 1,
        audioPts: 1,
        estimatedVfFps: 24,
        dropFrameCount: 0,
        voDropFrameCount: 0,
        voDelayedFrameCount: 0,
        hwdec: 'mediacodec-copy,auto-safe',
        hwdecCurrent: 'mediacodec-copy',
        vo: 'gpu',
        videoFormat: 'hevc',
        videoCodec: 'hevc',
        audioCodec: 'aac',
        vid: '1',
        pausedForCache: 'no',
        coreIdle: 'no',
        speed: 1,
        videoSync: 'display-resample',
        textureId: 3,
        width: 3840,
        height: 2160,
        decoderFrameDropCount: 2,
        containerFps: 60,
        cacheUsed: '12MiB',
        demuxerCacheDuration: '8.5',
        bufferedSec: 8,
        playerReused: true,
        mediaPath: 'https://example.test/av1',
        appScene: 'pip',
      ).codecFamily,
      'hevc',
    );
    expect(
      _snap().toLogLine(),
      contains('hwdecRequested=mediacodec,auto-safe'),
    );
    expect(_snap().toLogLine(), contains('hwdecCurrent=mediacodec'));
    expect(_snap().toLogLine(), contains('codec=avc'));
    expect(_snap().toLogLine(), contains('reusedPlayer=false'));
    expect(_snap().toLogLine(), contains('scene=foreground'));
  });
}
