import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/utils/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('in-app updater points at tyechan/PiliNara releases', () {
    expect(Api.latestApp, contains('tyechan/PiliNara/releases'));
    expect(Api.latestApp, isNot(contains('Starfallan/PiliNara')));
  });

  test('parses 10-digit versionCode from release name and assets', () {
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

  test('isRemoteNewer compares versionCode only', () {
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
