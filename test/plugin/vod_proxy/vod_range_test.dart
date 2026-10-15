import 'dart:math';

import 'package:PiliPlus/plugin/vod_proxy/vod_host_pool.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_range.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(pool.available.map((h) => h.host), contains('upos-sz-mirrorali.bilivideo.com'));
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
    expect(VodHostPool.isOverseasHost('upos-hz-mirrorakam.akamaized.net'), isTrue);
    expect(VodHostPool.isOverseasHost('upos-sz-mirrorcosov.bilivideo.com'), isFalse);
    expect(VodHostPool.isOverseasHost('upos-sz-mirrorali.bilivideo.com'), isFalse);
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
    banned.blacklistedUntil = DateTime.now().subtract(const Duration(seconds: 1));
    expect(
      pool.available.map((h) => h.host),
      contains('upos-sz-mirrorali.bilivideo.com'),
    );
  });
}
