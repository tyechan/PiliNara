import 'package:PiliPlus/plugin/pl_player/utils/orientation_policy.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const user = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];
  const landscapeOnly = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];
  const portraitOnly = [DeviceOrientation.portraitUp];
  const oneLandscape = [DeviceOrientation.landscapeLeft];

  test('USER and the manifest default can fall through to portrait', () {
    expect(preferredOrientationsAllowPortraitFallthrough(null), isTrue);
    expect(preferredOrientationsAllowPortraitFallthrough(user), isTrue);
  });

  test('portrait-only and landscape-only do not fall through', () {
    expect(
      preferredOrientationsAllowPortraitFallthrough(portraitOnly),
      isFalse,
    );
    expect(
      preferredOrientationsAllowPortraitFallthrough(landscapeOnly),
      isFalse,
    );
    expect(
      preferredOrientationsAllowPortraitFallthrough(oneLandscape),
      isFalse,
    );
  });

  test('reverse portrait keeps a landscape-only fullscreen', () {
    expect(
      shouldHoldLandscapeOnReversePortrait(
        isFullScreen: true,
        isVertical: false,
        lastSensor: DeviceOrientation.landscapeLeft,
        preferred: oneLandscape,
      ),
      isFalse,
    );
  });

  test('reverse portrait pins USER while a landscape video is fullscreen', () {
    expect(
      shouldHoldLandscapeOnReversePortrait(
        isFullScreen: true,
        isVertical: false,
        lastSensor: DeviceOrientation.landscapeRight,
        preferred: user,
      ),
      isTrue,
    );
    expect(
      shouldHoldLandscapeOnReversePortrait(
        isFullScreen: true,
        isVertical: false,
        lastSensor: DeviceOrientation.landscapeLeft,
        preferred: null,
      ),
      isTrue,
    );
  });

  test('reverse portrait leaves upright portrait alone', () {
    expect(
      shouldHoldLandscapeOnReversePortrait(
        isFullScreen: false,
        isVertical: false,
        lastSensor: DeviceOrientation.portraitUp,
        preferred: portraitOnly,
      ),
      isFalse,
    );
    expect(
      shouldHoldLandscapeOnReversePortrait(
        isFullScreen: false,
        isVertical: false,
        lastSensor: null,
        preferred: portraitOnly,
      ),
      isFalse,
    );
  });

  test('vertical fullscreen is not forced into landscape', () {
    expect(
      shouldHoldLandscapeOnReversePortrait(
        isFullScreen: true,
        isVertical: true,
        lastSensor: DeviceOrientation.portraitUp,
        preferred: portraitOnly,
      ),
      isFalse,
    );
  });

  test('last landscape reading pins USER even outside player fullscreen', () {
    expect(
      shouldHoldLandscapeOnReversePortrait(
        isFullScreen: false,
        isVertical: false,
        lastSensor: DeviceOrientation.landscapeLeft,
        preferred: user,
      ),
      isTrue,
    );
  });
}
