import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

const String kVodProxyLogTag = 'VodProxy';

/// Lightweight proxy traces (listen/size/stats/retry). Not written to Catcher.
abstract final class VodProxyLog {
  static void log(String message) {
    developer.log(message, name: kVodProxyLogTag);
    debugPrint('[$kVodProxyLogTag] $message');
  }
}
