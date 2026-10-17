import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const String kVodProxyLogTag = 'VodProxy';
const String kPlayLogTag = 'Play';

/// Proxy / playback traces for logcat and the in-app exportable log.
///
/// File sink is best-effort: tests can set [writeFile] = false.
abstract final class VodProxyLog {
  static int? firstFrameMs;
  static bool writeFile = true;
  static bool _booted = false;
  static bool _headerWritten = false;
  static final List<String> _memory = <String>[];
  static const int _maxMemory = 500;
  static const int _maxFileBytes = 512 * 1024;
  static Future<void> _io = Future<void>.value();
  static File? _file;

  static List<String> get memoryLines => List<String>.unmodifiable(_memory);

  static String get exportedText => _memory.join('\n');

  static String get bootLine {
    final hash = BuildConfig.commitHash;
    final short = hash.length >= 7 ? hash.substring(0, 7) : hash;
    return 'boot build=${BuildConfig.versionName}+$short '
        'code=${BuildConfig.versionCode} '
        'name=${BuildConfig.displayVersion}';
  }

  static void resetForTest() {
    _memory.clear();
    _booted = false;
    _headerWritten = false;
    firstFrameMs = null;
    writeFile = false;
    _file = null;
    _io = Future<void>.value();
  }

  static void log(String message, {String tag = kVodProxyLogTag}) {
    if (!_booted) {
      _booted = true;
      _emit(bootLine, tag: kVodProxyLogTag);
    }
    _emit(message, tag: tag);
  }

  static void play(String message) => log(message, tag: kPlayLogTag);

  /// Never log signed CDN URLs or mpv stream ids like `audio2`.
  static String safeTitle(String? title) {
    if (title == null) return '-';
    final t = title.trim().replaceAll(RegExp(r'[\r\n]+'), ' ');
    if (t.isEmpty || t == '-') return '-';
    final lower = t.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('edl://')) {
      return '-';
    }
    if (RegExp(r'^(video|audio)\d+$', caseSensitive: false).hasMatch(t)) {
      return '-';
    }
    if (t.contains('deadline=') ||
        t.contains('os=') ||
        t.contains('bilivideo') ||
        t.contains('akamaized')) {
      return '-';
    }
    return t;
  }

  static String hostOnly(String? url) {
    if (url == null || url.isEmpty) return '-';
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return '-';
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return '-';
    }
    return host;
  }

  static void _emit(String message, {required String tag}) {
    final line = '[$tag] $message';
    debugPrint(line);
    developer.log(message, name: tag);
    _memory.add(line);
    if (_memory.length > _maxMemory) {
      _memory.removeRange(0, _memory.length - _maxMemory);
    }
    if (writeFile) {
      _io = _io.then((_) => _append(line));
    }
  }

  static Future<void> _append(String line) async {
    try {
      final file = _file ??= await _open();
      if (!_headerWritten) {
        _headerWritten = true;
        await file.writeAsString(
          '# ${bootLine}\n',
          mode: FileMode.writeOnlyAppend,
          flush: false,
        );
      }
      await file.writeAsString(
        '${jsonEncode({'t': DateTime.now().toIso8601String(), 'line': line})}\n',
        mode: FileMode.writeOnlyAppend,
        flush: true,
      );
      final len = await file.length();
      if (len > _maxFileBytes) {
        await _rotate(file);
      }
    } catch (_) {
      // File sink is diagnostic only.
    }
  }

  static Future<File> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/.pili_vod.log');
  }

  static Future<void> _rotate(File file) async {
    try {
      final text = await file.readAsString();
      final keep = text.length > _maxFileBytes ~/ 2
          ? text.substring(text.length - _maxFileBytes ~/ 2)
          : text;
      await file.writeAsString('# $bootLine\n$keep', flush: true);
    } catch (_) {}
  }

  static Future<String> readExportedFile() async {
    try {
      final file = _file ?? await _open();
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (_) {}
    return exportedText;
  }
}
