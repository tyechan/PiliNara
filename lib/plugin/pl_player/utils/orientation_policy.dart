import 'package:flutter/services.dart' show DeviceOrientation;

/// True when the requested orientations are `SCREEN_ORIENTATION_USER`
/// (portrait plus at least one landscape), including the manifest default.
///
/// That mode does not use reverse portrait, but an upside-down reading falls
/// through to upright portrait and will rotate a landscape activity.
bool preferredOrientationsAllowPortraitFallthrough(
  List<DeviceOrientation>? preferred,
) {
  if (preferred == null) return true;
  final portrait =
      preferred.contains(DeviceOrientation.portraitUp) ||
      preferred.contains(DeviceOrientation.portraitDown);
  final landscape =
      preferred.contains(DeviceOrientation.landscapeLeft) ||
      preferred.contains(DeviceOrientation.landscapeRight);
  return portrait && landscape;
}

/// A reverse-portrait reading never changes the current orientation by itself.
///
/// Pin the activity to the two landscapes only when it is still on
/// `SCREEN_ORIENTATION_USER` and the UI is already in sensor landscape
/// (fullscreen video, or the last real sensor reading was a landscape).
/// Portrait-only and landscape-only requests are not touched.
bool shouldHoldLandscapeOnReversePortrait({
  required bool isFullScreen,
  required bool isVertical,
  required DeviceOrientation? lastSensor,
  required List<DeviceOrientation>? preferred,
}) {
  final wasLandscape =
      lastSensor == .landscapeLeft || lastSensor == .landscapeRight;
  final fullscreenLandscape = isFullScreen && !isVertical;
  if (!wasLandscape && !fullscreenLandscape) return false;
  return preferredOrientationsAllowPortraitFallthrough(preferred);
}
