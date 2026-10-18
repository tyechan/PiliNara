import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
import 'package:PiliPlus/utils/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('in-app updater points at tyechan/PiliNara releases', () {
    expect(Api.latestApp, contains('tyechan/PiliNara/releases'));
    expect(Api.latestApp, isNot(contains('Starfallan/PiliNara')));
  });

  test('parses 10-digit versionCode from short fork names', () {
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.6.1.1-1018b+abc1234',
        name: 'PiliPala 2.6.1.1-1018b+abc1234 (2026101802)',
      ),
      2026101802,
    );
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.1.6-1017a+abc1234',
        name: 'PiliPala 2.1.6-1017a+abc1234 (2026101701)',
      ),
      2026101701,
    );
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.1.6-1016c+abc1234',
        name: 'PiliPala 2.1.6-1016c+abc1234 (2026101603)',
      ),
      2026101603,
    );
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.1.6-1016b+abc1234',
        name: 'PiliPala 2.1.6-1016b+abc1234 (2026101602)',
      ),
      2026101602,
    );
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.1.6-1016a+abc1234',
        name: 'PiliPala 2.1.6-1016a+abc1234 (2026101601)',
      ),
      2026101601,
    );
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.1.6-20261015-btr-proxy+abc1234',
        name: 'PiliPala 2.1.6-20261015-btr-proxy+abc1234 (2026101503)',
      ),
      2026101503,
    );
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.1.6-20261015-btr-proxy+abc1234',
        assetNames: const [
          'PiliPala-2.1.6-20261015-btr-proxy-abc1234-2026101503_arm64-v8a.apk',
        ],
      ),
      2026101503,
    );
  });

  test('falls back to YYYYMMDD00 when old tags omit versionCode', () {
    expect(
      Update.parseRemoteVersionCode(
        tagName: 'v2.1.6-20261015-btr-proxy+9556d20',
        name: 'PiliNara 2.1.6-20261015-btr-proxy+9556d20',
      ),
      2026101500,
    );
  });

  test('does not treat 8-digit date as versionCode', () {
    expect(
      Update.parseRemoteVersionCode(name: 'notes 20261015 only'),
      isNull,
    );
  });

  test('About displayVersion is a short one-liner', () {
    expect(BuildConfig.displayVersion.length, lessThanOrEqualTo(24));
    expect(BuildConfig.displayVersion, '2.6.1.1 · 1018 · dev');
    expect(BuildConfig.versionName.length, lessThanOrEqualTo(16));
    expect(BuildConfig.versionName, '2.6.1.1-1018b');
    expect(VodProxyLog.bootLine, contains('2.6.1.1-1018b'));
    expect(VodProxyLog.bootLine, contains('2026101802'));
    expect(BuildConfig.displayVersion, contains('2.6.1.1 · 1018'));
    expect(BuildConfig.displayVersion.split('\n'), hasLength(1));
    expect(VodProxyLog.safeTitle('audio2'), '-');
    expect(
      VodProxyLog.safeTitle(
        'https://upos-sz-mirrorali.bilivideo.com/a.m4s?deadline=1',
      ),
      '-',
    );
    expect(VodProxyLog.safeTitle('真正的标题'), '真正的标题');
    expect(
      VodProxyLog.hostOnly('https://upos-sz-mirrorali.bilivideo.com/a.m4s?e=1'),
      'upos-sz-mirrorali.bilivideo.com',
    );
    expect(VodProxyLog.hostOnly('http://127.0.0.1:9/video1'), '-');
  });

  test('isRemoteNewer compares versionCode only', () {
    expect(
      Update.isRemoteNewer(
        localVersionCode: 2026101703,
        remoteVersionCode: 2026101802,
      ),
      isTrue,
    );
    expect(
      Update.isRemoteNewer(
        localVersionCode: 2026101502,
        remoteVersionCode: 2026101503,
      ),
      isTrue,
    );
    expect(
      Update.isRemoteNewer(
        localVersionCode: 2026101503,
        remoteVersionCode: 2026101503,
      ),
      isFalse,
    );
    expect(
      Update.isRemoteNewer(
        localVersionCode: 2026101503,
        remoteVersionCode: 2026101500,
      ),
      isFalse,
    );
    expect(
      Update.isRemoteNewer(
        localVersionCode: 2026101503,
        remoteVersionCode: null,
      ),
      isFalse,
    );
  });
}
