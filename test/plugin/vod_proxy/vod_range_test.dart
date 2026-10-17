import 'dart:math';

import 'package:PiliPlus/plugin/vod_proxy/playback_diag.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_health.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_pool.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_lavf.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_range.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_session.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    VodHostHealth.instance.resetForTest();
    VodProxyLog.resetForTest();
  });

  group('splitRanges', () {
    test('splits a span into fixed chunks', () {
      expect(
        splitRanges(0, 1000, 256),
        [
          const ByteRange(0, 256),
          const ByteRange(256, 512),
          const ByteRange(512, 768),
          const ByteRange(768, 1000),
        ],
      );
    });

    test('returns empty on inverted or zero inputs', () {
      expect(splitRanges(10, 10, 256), isEmpty);
      expect(splitRanges(0, 10, 0), isEmpty);
    });
  });

  group('HttpRangeRequest', () {
    test('parses open and closed ranges', () {
      expect(HttpRangeRequest.parse('bytes=100-199')?.start, 100);
      expect(HttpRangeRequest.parse('bytes=100-199')?.endInclusive, 199);
      expect(HttpRangeRequest.parse('bytes=500-')?.endInclusive, isNull);
      expect(HttpRangeRequest.parse('bytes=500-')?.start, 500);
    });

    test('resolves suffix and open ranges against file size', () {
      expect(
        const HttpRangeRequest(start: 0).resolve(1000),
        const ByteRange(0, 1000),
      );
      expect(
        HttpRangeRequest.parse('bytes=-200')!.resolve(1000),
        const ByteRange(800, 1000),
      );
      expect(
        HttpRangeRequest.parse('bytes=100-199')!.resolve(150),
        const ByteRange(100, 150),
      );
    });

    test('rejects inverted ranges', () {
      expect(HttpRangeRequest.parse('bytes=20-10'), isNull);
      expect(HttpRangeRequest.parse('foobar'), isNull);
    });
  });

  group('ContentRangeReply', () {
    test('parses and matches exact 206 replies', () {
      final parsed = ContentRangeReply.parse('bytes 512-1023/4096');
      expect(parsed, isNotNull);
      expect(parsed!.start, 512);
      expect(parsed.endInclusive, 1023);
      expect(parsed.total, 4096);
      expect(parsed.matches(start: 512, endInclusive: 1023), isTrue);
      expect(parsed.matches(start: 0, endInclusive: 1023), isFalse);
    });

    test('rejects a range that overruns the total', () {
      expect(ContentRangeReply.parse('bytes 0-99/50'), isNull);
    });

    test('covers a wider CDN window than the request', () {
      final parsed = ContentRangeReply.parse('bytes 0-4095/38872044');
      expect(parsed!.covers(start: 0, endInclusive: 0), isTrue);
      expect(parsed.covers(start: 0, endInclusive: 4095), isTrue);
      expect(parsed.covers(start: 100, endInclusive: 200), isTrue);
      expect(parsed.covers(start: 4096, endInclusive: 5000), isFalse);
    });
  });

  test('parsePlayurlDeadline reads the query param', () {
    expect(
      parsePlayurlDeadline(
        'https://upos.example/a.m4s?deadline=1791805380&os=cosov',
      ),
      1791805380,
    );
    expect(parsePlayurlDeadline('https://upos.example/a.m4s'), isNull);
  });

  test('candidateMediaUrls keeps original plus mainland hosts', () {
    const primary =
        'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/1.m4s?e=1';
    const backup =
        'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1.m4s?e=1';
    final urls = VideoUtils.candidateMediaUrls(primary, extras: [backup]);
    final hosts = urls.map((u) => Uri.parse(u).host).toList();
    expect(hosts.first, 'upos-sz-mirrorcosov.bilivideo.com');
    expect(hosts, contains('upos-sz-mirrorali.bilivideo.com'));
    expect(hosts, contains('upos-sz-mirrorhw.bilivideo.com'));
    expect(hosts, contains('upos-hz-mirrorakam.akamaized.net'));
    expect(hosts.toSet().length, hosts.length);
  });

  test('host pool blacklists only after repeated failures', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw], random: Random(1));
    pool.recordSuccess(ali, bytes: 256 * 1024, elapsedMs: 400);
    pool.recordSuccess(hw, bytes: 512 * 1024, elapsedMs: 200);
    expect(pool.preferred?.host, 'upos-sz-mirrorhw.bilivideo.com');
    pool.recordFailure(ali, reason: 'TimeoutException');
    expect(
      pool.available.map((h) => h.host),
      contains('upos-sz-mirrorali.bilivideo.com'),
    );
    pool.recordFailure(ali, reason: 'TimeoutException');
    pool.recordFailure(ali, reason: 'TimeoutException');
    expect(
      pool.available.map((h) => h.host),
      isNot(contains('upos-sz-mirrorali.bilivideo.com')),
    );
    pool.preferNext();
    expect(pool.preferred?.host, isNot('upos-sz-mirrorhw.bilivideo.com'));
  });

  test('pickUrl spreads workers across the fastest hosts', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    const cos = 'https://upos-sz-mirrorcos.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw, cos], random: Random(2));
    pool.recordSuccess(ali, bytes: 256 * 1024, elapsedMs: 200);
    pool.recordSuccess(hw, bytes: 256 * 1024, elapsedMs: 180);
    pool.recordSuccess(cos, bytes: 256 * 1024, elapsedMs: 800);
    final counts = <String, int>{};
    for (var i = 0; i < 80; i++) {
      final host = Uri.parse(pool.pickUrl()!).host;
      counts[host] = (counts[host] ?? 0) + 1;
    }
    expect(counts.length, greaterThanOrEqualTo(2));
    expect(counts['upos-sz-mirrorali.bilivideo.com'] ?? 0, greaterThan(0));
    expect(counts['upos-sz-mirrorhw.bilivideo.com'] ?? 0, greaterThan(0));
  });

  test('overseas hosts are scored lower unless they win the probe', () {
    expect(
      VodHostPool.isOverseasHost('upos-hz-mirrorakam.akamaized.net'),
      isTrue,
    );
    expect(
      VodHostPool.isOverseasHost('upos-sz-mirrorcosov.bilivideo.com'),
      isFalse,
    );
    expect(
      VodHostPool.isOverseasHost('upos-sz-mirrorali.bilivideo.com'),
      isFalse,
    );
    const akam = 'https://upos-hz-mirrorakam.akamaized.net/a.m4s';
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    final pool = VodHostPool([akam, ali], random: Random(1));
    pool.recordSuccess(akam, bytes: 128 * 1024, elapsedMs: 300);
    pool.recordSuccess(ali, bytes: 128 * 1024, elapsedMs: 400);
    pool.overseasWins = false;
    expect(pool.preferred?.host, 'upos-sz-mirrorali.bilivideo.com');
    pool.overseasWins = true;
    expect(pool.preferred?.host, 'upos-hz-mirrorakam.akamaized.net');
  });

  test('compact stats omit idle hosts', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw]);
    pool.recordSuccess(ali, bytes: 1024, elapsedMs: 100);
    expect(pool.describe(), contains('mirrorali'));
    expect(pool.describe(), isNot(contains('mirrorhw')));
  });

  test('compact stats omit probe-only hosts', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw]);
    pool.recordSuccess(hw, bytes: 128 * 1024, elapsedMs: 200, probe: true);
    pool.recordSuccess(ali, bytes: 512 * 1024, elapsedMs: 100);
    expect(pool.describe(), contains('mirrorali'));
    expect(pool.describe(), isNot(contains('mirrorhw')));
    expect(pool.sessionHostSummary(), isNot(contains('mirrorhw')));
    pool.recordFailure(hw, reason: 'TimeoutException', probe: true);
    expect(pool.describe(), isNot(contains('mirrorhw')));
    pool.recordFailure(hw, reason: 'TimeoutException');
    expect(pool.describe(), contains('mirrorhw'));
  });

  test('3 timeouts in 30s ban even when successes interleave', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw], random: Random(1));
    pool.recordSuccess(ali, bytes: 256 * 1024, elapsedMs: 100);
    pool.recordFailure(ali, reason: 'TimeoutException');
    pool.recordSuccess(ali, bytes: 256 * 1024, elapsedMs: 100);
    pool.recordFailure(ali, reason: 'TimeoutException');
    pool.recordSuccess(ali, bytes: 256 * 1024, elapsedMs: 100);
    expect(
      pool.available.map((h) => h.host),
      contains('upos-sz-mirrorali.bilivideo.com'),
    );
    pool.recordFailure(ali, reason: 'TimeoutException');
    expect(
      pool.available.map((h) => h.host),
      isNot(contains('upos-sz-mirrorali.bilivideo.com')),
    );
  });

  test('unban after cooldown logs a retry', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw], random: Random(1));
    for (var i = 0; i < VodHostPool.banAfterErrors; i++) {
      pool.recordFailure(ali, reason: 'TimeoutException');
    }
    expect(
      pool.available.map((h) => h.host),
      isNot(contains('upos-sz-mirrorali.bilivideo.com')),
    );
    final banned = pool.hosts.firstWhere((h) => h.host.contains('mirrorali'));
    banned.blacklistedUntil = DateTime.now().subtract(
      const Duration(seconds: 1),
    );
    banned.bannedAt = DateTime.now().subtract(const Duration(seconds: 31));
    expect(
      pool.available.map((h) => h.host),
      contains('upos-sz-mirrorali.bilivideo.com'),
    );
  });

  test('pickUrl never retries a banned host while others are open', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw], random: Random(1));
    for (var i = 0; i < VodHostPool.banAfterErrors; i++) {
      pool.recordFailure(ali, reason: 'TimeoutException');
    }
    expect(
      pool.available.map((h) => h.host),
      isNot(contains('upos-sz-mirrorali.bilivideo.com')),
    );
    for (var i = 0; i < 12; i++) {
      expect(
        Uri.parse(pool.pickUrl()!).host,
        'upos-sz-mirrorhw.bilivideo.com',
      );
      expect(
        Uri.parse(pool.pickUrl(allowBanned: true)!).host,
        'upos-sz-mirrorhw.bilivideo.com',
      );
    }
    pool.recordFailure(hw, reason: 'TimeoutException');
    pool.recordFailure(hw, reason: 'TimeoutException');
    pool.recordFailure(hw, reason: 'TimeoutException');
    expect(pool.available, isEmpty);
    expect(pool.pickUrl(), isNull);
    expect(
      Uri.parse(pool.pickUrl(allowBanned: true)!).host,
      anyOf(
        'upos-sz-mirrorali.bilivideo.com',
        'upos-sz-mirrorhw.bilivideo.com',
      ),
    );
  });

  test('describe refreshes bans and logs unban after cooldown', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw], random: Random(1));
    for (var i = 0; i < VodHostPool.banAfterErrors; i++) {
      pool.recordFailure(ali, reason: 'TimeoutException');
    }
    final banned = pool.hosts.firstWhere((h) => h.host.contains('mirrorali'));
    banned.blacklistedUntil = DateTime.now().subtract(
      const Duration(seconds: 1),
    );
    banned.bannedAt = DateTime.now().subtract(const Duration(seconds: 31));
    pool.describe();
    expect(banned.blacklistedUntil, isNull);
    expect(
      VodProxyLog.memoryLines.any(
        (l) => l.contains('unban host=upos-sz-mirrorali.bilivideo.com'),
      ),
      isTrue,
    );
  });

  test('freeze detector uses video-pts/frames not wall time-pos', () {
    expect(
      PlaybackDiag.freezeVideoMoved(
        frame: 10,
        lastFrame: 10,
        videoPts: 1.0,
        lastVideoPts: 1.0,
      ),
      isFalse,
    );
    expect(
      PlaybackDiag.freezeAudioMoved(audioPts: 1.5, lastAudioPts: 1.0),
      isTrue,
    );
    expect(
      PlaybackDiag.freezeVideoMoved(
        frame: 11,
        lastFrame: 10,
        videoPts: 1.0,
        lastVideoPts: 1.0,
      ),
      isTrue,
    );
    expect(
      PlaybackDiag.freezeVideoMoved(
        frame: 10,
        lastFrame: 10,
        videoPts: 1.4,
        lastVideoPts: 1.0,
      ),
      isTrue,
    );
  });

  test('video-slow host is ranked last and remembered app-wide', () {
    const slow = 'https://upos-sz-mirrorcosov.bilivideo.com/a.m4s';
    const fast = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    VodHostHealth.instance.noteVideoProbe(
      'upos-sz-mirrorcosov.bilivideo.com',
      ttfbMs: 2100,
      thruMbps: 0.45,
    );
    expect(
      VodHostHealth.instance.isVideoSlow('upos-sz-mirrorcosov.bilivideo.com'),
      isTrue,
    );
    final pool = VodHostPool([slow, fast], random: Random(1));
    pool.recordSuccess(slow, bytes: 256 * 1024, elapsedMs: 4000, ttfbMs: 2100);
    pool.recordSuccess(fast, bytes: 256 * 1024, elapsedMs: 200, ttfbMs: 40);
    expect(
      pool.topHosts(k: 2, kind: 'video').first.host,
      'upos-sz-mirrorhw.bilivideo.com',
    );
    expect(
      pool.topHosts(k: 2, kind: 'video').last.host,
      'upos-sz-mirrorcosov.bilivideo.com',
    );
  });

  test('unban does not fire before the 30s floor', () {
    VodProxyLog.resetForTest();
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final pool = VodHostPool([ali, hw], random: Random(1));
    for (var i = 0; i < VodHostPool.banAfterErrors; i++) {
      pool.recordFailure(ali, reason: 'TimeoutException');
    }
    final banned = pool.hosts.firstWhere((h) => h.host.contains('mirrorali'));
    banned.blacklistedUntil = DateTime.now().subtract(
      const Duration(seconds: 1),
    );
    banned.bannedAt = DateTime.now().subtract(const Duration(seconds: 2));
    expect(
      pool.available.map((h) => h.host),
      isNot(contains('upos-sz-mirrorali.bilivideo.com')),
    );
    expect(
      VodProxyLog.memoryLines.any((l) => l.contains('unban host=')),
      isFalse,
    );
  });

  test('app-wide ban is consulted by a fresh pool', () {
    const ali = 'https://upos-sz-mirrorali.bilivideo.com/a.m4s';
    const hw = 'https://upos-sz-mirrorhw.bilivideo.com/a.m4s';
    final first = VodHostPool([ali, hw], random: Random(1));
    for (var i = 0; i < VodHostPool.banAfterErrors; i++) {
      first.recordFailure(ali, reason: 'TimeoutException');
    }
    expect(
      VodHostHealth.instance.isBanned('upos-sz-mirrorali.bilivideo.com'),
      isTrue,
    );
    final next = VodHostPool([ali, hw], random: Random(2));
    for (var i = 0; i < 8; i++) {
      expect(
        Uri.parse(next.pickUrl()!).host,
        'upos-sz-mirrorhw.bilivideo.com',
      );
    }
  });

  test('direct lavf timeout is 15s and proxy stays at 60s', () {
    expect(VodLavf.directNetworkTimeout, '15');
    expect(VodLavf.directStream, contains('timeout=15000000'));
    expect(VodLavf.directStream, contains('rw_timeout=15000000'));
    expect(VodLavf.directStream, contains('reconnect=1'));
    expect(VodLavf.directStream, contains('reconnect_on_network_error=1'));
    expect(VodLavf.proxyNetworkTimeout, '60');
    expect(VodLavf.proxyStream, contains('timeout=60000000'));
    expect(VodSession.minBackBufferBytes, 192 * 1024 * 1024);
    expect(VodSession.defaultBackBuffer(8 * 1024 * 1024), 192 * 1024 * 1024);
    expect(VodSession.defaultBackBuffer(256 * 1024 * 1024), 256 * 1024 * 1024);
  });

  test(
    'first-frame-stuck fires when video-pts never leaves the opening frame',
    () {
      expect(
        PlaybackDiag.freezeFirstFrameStuck(
          videoMoved: false,
          videoPts: null,
          lastVideoPts: null,
          audioMoved: true,
        ),
        isTrue,
      );
      expect(
        PlaybackDiag.freezeFirstFrameStuck(
          videoMoved: false,
          videoPts: 0.0,
          lastVideoPts: 0.0,
          audioMoved: true,
        ),
        isTrue,
      );
      expect(
        PlaybackDiag.freezeFirstFrameStuck(
          videoMoved: true,
          videoPts: null,
          lastVideoPts: null,
          audioMoved: true,
        ),
        isFalse,
      );
      expect(
        PlaybackDiag.freezeVideoStuck(
          videoMoved: false,
          earlyEnd: false,
          videoPts: null,
          frame: null,
          firstFrame: true,
        ),
        isTrue,
      );
      expect(
        PlaybackDiag.freezeAudioMoved(
          audioPts: null,
          lastAudioPts: null,
          timePosSec: 4.0,
          lastTimePosSec: 1.0,
          clockFallback: true,
        ),
        isTrue,
      );
    },
  );

  test('freeze detector fires after partial-file when video-pts is gone', () {
    expect(
      PlaybackDiag.freezeVideoStuck(
        videoMoved: false,
        earlyEnd: true,
        videoPts: null,
        frame: null,
      ),
      isTrue,
    );
    expect(
      PlaybackDiag.freezeAudioMoved(
        audioPts: null,
        lastAudioPts: null,
        timePosSec: 12.0,
        lastTimePosSec: 10.0,
        earlyEnd: true,
      ),
      isTrue,
    );
    expect(
      PlaybackDiag.freezeAudioMoved(
        audioPts: null,
        lastAudioPts: null,
        timePosSec: 10.0,
        lastTimePosSec: 10.0,
        earlyEnd: true,
      ),
      isFalse,
    );
  });

  test('recover allows five attempts per minute then give-up', () {
    final t0 = DateTime.utc(2026, 10, 17, 12);
    final attempts = <DateTime>[];
    for (var i = 0; i < 5; i++) {
      expect(
        PlaybackDiag.recoverDecision(
          attempts: attempts,
          now: t0.add(Duration(seconds: 3 * i)),
        ),
        isNull,
      );
      attempts.add(t0.add(Duration(seconds: 3 * i)));
    }
    expect(
      PlaybackDiag.recoverDecision(
        attempts: attempts,
        now: t0.add(const Duration(seconds: 14)),
      ),
      'give-up',
    );
    expect(
      PlaybackDiag.recoverDecision(
        attempts: [t0],
        now: t0.add(const Duration(milliseconds: 500)),
      ),
      'cooldown',
    );
    expect(
      PlaybackDiag.recoverDecision(
        attempts: attempts,
        now: t0.add(const Duration(minutes: 2)),
      ),
      isNull,
    );
  });
}
