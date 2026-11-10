import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:flutter/services.dart'
    show SystemChrome, SystemUiOverlay, DeviceOrientation;

bool _isDesktopFullScreen = false;

void enterDesktopFullScreen({bool inAppFullScreen = false}) {
  if (!inAppFullScreen && !_isDesktopFullScreen) {
    WindowController.instance.window?.isFullScreen = _isDesktopFullScreen =
        true;
  }
}

void exitDesktopFullScreen() {
  if (_isDesktopFullScreen) {
    WindowController.instance.window?.isFullScreen = _isDesktopFullScreen =
        false;
  }
}

List<DeviceOrientation>? _lastOrientation;

/// Last set passed to [SystemChrome.setPreferredOrientations], or null when
/// the activity is still on the manifest default (`SCREEN_ORIENTATION_USER`).
List<DeviceOrientation>? get preferredOrientations => _lastOrientation;

Future<void>? _setPreferredOrientations(List<DeviceOrientation> orientations) {
  if (DeviceUtils.isChromeOS) return null;

  if (_lastOrientation == orientations) {
    return null;
  }
  _lastOrientation = orientations;
  return SystemChrome.setPreferredOrientations(orientations);
}

Future<void>? portraitUpMode() {
  return _setPreferredOrientations(const [.portraitUp]);
}

Future<void>? landscapeLeftMode() {
  return _setPreferredOrientations(const [.landscapeLeft]);
}

Future<void>? landscapeRightMode() {
  return _setPreferredOrientations(const [.landscapeRight]);
}

/// Portrait plus both landscapes.
///
/// [DeviceOrientation.portraitDown] is intentionally absent. Flutter turns the
/// four-way set into `SCREEN_ORIENTATION_FULL_USER`, which rotates a phone
/// upside down. This three-way set becomes `SCREEN_ORIENTATION_USER`: landscape
/// auto-rotation still works, reverse portrait is not an allowed orientation.
///
/// `SCREEN_ORIENTATION_USER` still falls through to upright portrait when the
/// sensor reads reverse portrait. While a video is sensor-landscape, call
/// [holdLandscapeAgainstReversePortrait] so the activity is landscape-only.
Future<void>? fullMode() {
  return _setPreferredOrientations(
    const [.portraitUp, .landscapeLeft, .landscapeRight],
  );
}

/// Both landscapes and no portrait (`SCREEN_ORIENTATION_USER_LANDSCAPE`).
///
/// Used when the activity is still on `SCREEN_ORIENTATION_USER` and gravity
/// reports reverse portrait. The current landscape stays; the OS cannot snap
/// it to upright portrait. A portrait-only request is left alone.
Future<void>? holdLandscapeAgainstReversePortrait() {
  final last = _lastOrientation;
  if (last != null) {
    final portrait =
        last.contains(DeviceOrientation.portraitUp) ||
        last.contains(DeviceOrientation.portraitDown);
    final landscape =
        last.contains(DeviceOrientation.landscapeLeft) ||
        last.contains(DeviceOrientation.landscapeRight);
    // Portrait-only stays portrait. Landscape-only is already safe.
    if (!portrait || !landscape) return null;
  }
  return _setPreferredOrientations(const [.landscapeLeft, .landscapeRight]);
}

bool _showSystemBar = true;
bool get showSystemBar_ => _showSystemBar;
Future<void>? hideSystemBar() {
  if (!_showSystemBar) {
    return null;
  }
  _showSystemBar = false;
  return SystemChrome.setEnabledSystemUIMode(.immersiveSticky);
}

//退出全屏显示
Future<void>? showSystemBar() {
  if (_showSystemBar) {
    return null;
  }
  _showSystemBar = true;
  return SystemChrome.setEnabledSystemUIMode(
    Platform.isAndroid && DeviceUtils.sdkInt < 29 ? .manual : .edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
}
