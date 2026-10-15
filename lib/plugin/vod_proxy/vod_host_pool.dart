import 'dart:math' show Random;

import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_range.dart';
import 'package:PiliPlus/utils/video_utils.dart';

class VodHostStat {
  VodHostStat(this.url)
    : host = (Uri.tryParse(url)?.host ?? url).toLowerCase();

  final String url;
  final String host;
  double emaBps = 0;
  double peakBps = 0;
  int successes = 0;
  int errors = 0;
  int consecutiveErrors = 0;
  int bytes = 0;
  int ttfbMs = 0;
  int ttfbSamples = 0;
  DateTime? blacklistedUntil;
  String? lastBanReason;

  bool get isOverseas => VodHostPool.isOverseasHost(host);

  double get avgTtfbMs => ttfbSamples == 0 ? 0 : ttfbMs / ttfbSamples;

  bool get hasTraffic => bytes > 0 || successes > 0 || errors > 0;
}

class VodHostPool {
  VodHostPool(List<String> urls, {Random? random})
    : _hosts = _unique(urls),
      _random = random ?? Random();

  final List<VodHostStat> _hosts;
  final Random _random;
  int _rotate = 0;
  bool overseasWins = false;
  final List<String> banReasons = <String>[];
  int unbanCount = 0;

  static const int banAfterErrors = 3;
  static const Duration defaultBan = Duration(seconds: 30);

  static List<VodHostStat> _unique(List<String> urls) {
    final seen = <String>{};
    final out = <VodHostStat>[];
    for (final url in urls) {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      if (host.isEmpty || !seen.add(host)) continue;
      out.add(VodHostStat(url));
    }
    return out;
  }

  static bool isOverseasHost(String host) {
    final h = host.toLowerCase();
    if (h.contains('akamai') || h.contains('akam') || h.contains('akamaized')) {
      return true;
    }
    if (h.contains('mirrorhwov') || h.contains('mirroraliov')) {
      return true;
    }
    // cosov is a mainland Volcengine node, not overseas.
    if (h.contains('cosov')) return false;
    return h.contains('ov.');
  }

  List<VodHostStat> get hosts => List.unmodifiable(_hosts);

  List<VodHostStat> get available {
    _refreshBans();
    return _hosts.where((h) => h.blacklistedUntil == null).toList();
  }

  VodHostStat? get preferred {
    final open = _ranked(available);
    if (open.isEmpty) return _hosts.isEmpty ? null : _hosts.first;
    return open.first;
  }

  List<VodHostStat> topHosts({int k = 3}) {
    final ranked = _ranked(available);
    if (ranked.isEmpty) return const [];
    return ranked.take(k).toList();
  }

  /// Spread workers across the 2–3 best hosts, weighted by measured throughput.
  String? pickUrl({String? avoidHost}) {
    var open = available;
    if (open.isEmpty) {
      if (_hosts.isEmpty) return null;
      return _hosts[_rotate++ % _hosts.length].url;
    }
    if (avoidHost != null) {
      final avoid = avoidHost.toLowerCase();
      final filtered = open.where((h) => h.host != avoid).toList();
      if (filtered.isNotEmpty) open = filtered;
    }
    final top = _ranked(open).take(3).toList();
    if (top.isEmpty) return open.first.url;
    if (top.every((h) => h.emaBps <= 0)) {
      return top[_rotate++ % top.length].url;
    }
    var total = 0.0;
    final weights = <double>[];
    for (final h in top) {
      final w = h.emaBps > 0 ? h.emaBps : 1.0;
      weights.add(w);
      total += w;
    }
    var ticket = _random.nextDouble() * total;
    for (var i = 0; i < top.length; i++) {
      ticket -= weights[i];
      if (ticket <= 0) return top[i].url;
    }
    return top.last.url;
  }

  List<VodHostStat> _ranked(List<VodHostStat> open) {
    final copy = [...open];
    copy.sort((a, b) {
      final sa = _score(a);
      final sb = _score(b);
      final cmp = sb.compareTo(sa);
      if (cmp != 0) return cmp;
      return a.errors.compareTo(b.errors);
    });
    return copy;
  }

  double _score(VodHostStat h) {
    var score = h.emaBps > 0 ? h.emaBps : 1.0;
    if (h.isOverseas && !overseasWins) {
      score *= 0.2;
    }
    return score;
  }

  VodHostStat? _find(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    for (final h in _hosts) {
      if (h.host == host) return h;
    }
    return null;
  }

  void recordSuccess(
    String url, {
    required int bytes,
    required int elapsedMs,
    int? ttfbMs,
  }) {
    final stat = _find(url);
    if (stat == null) return;
    stat.successes++;
    stat.consecutiveErrors = 0;
    stat.bytes += bytes;
    if (ttfbMs != null && ttfbMs > 0) {
      stat.ttfbMs += ttfbMs;
      stat.ttfbSamples++;
    }
    if (elapsedMs > 0 && bytes > 0) {
      final bps = bytes * 1000 / elapsedMs;
      stat.emaBps = stat.emaBps <= 0 ? bps : (stat.emaBps * 0.7 + bps * 0.3);
      if (bps > stat.peakBps) stat.peakBps = bps;
    }
  }

  void recordFailure(
    String url, {
    required String reason,
    Duration ban = defaultBan,
  }) {
    final stat = _find(url);
    if (stat == null) return;
    stat.errors++;
    stat.consecutiveErrors++;
    final timeoutLike =
        reason.contains('Timeout') ||
        reason.contains('reset') ||
        reason.contains('Connection closed') ||
        reason.contains('Connection reset') ||
        reason == '403' ||
        reason == 'short-read';
    if (stat.consecutiveErrors >= banAfterErrors && timeoutLike) {
      stat.blacklistedUntil = DateTime.now().add(ban);
      stat.lastBanReason = reason;
      banReasons.add('${stat.host}:$reason');
      VodProxyLog.log(
        'ban host=${stat.host} reason=$reason n=${stat.consecutiveErrors} '
        'cooldown=${ban.inSeconds}s',
      );
    }
  }

  void markOverseasWinnerIfNeeded() {
    final measured = _hosts.where((h) => h.emaBps > 0).toList();
    if (measured.isEmpty) {
      overseasWins = false;
      return;
    }
    measured.sort((a, b) => b.emaBps.compareTo(a.emaBps));
    overseasWins = measured.first.isOverseas;
  }

  void _refreshBans() {
    final now = DateTime.now();
    for (final h in _hosts) {
      final until = h.blacklistedUntil;
      if (until != null && !now.isBefore(until)) {
        h.blacklistedUntil = null;
        h.consecutiveErrors = 0;
        unbanCount++;
        VodProxyLog.log('unban host=${h.host} retry');
      }
    }
  }

  /// Stall recovery: ban the current preferred host so the next fetch moves.
  String? preferNext() {
    final cur = preferred;
    if (cur == null) return null;
    cur.blacklistedUntil = DateTime.now().add(const Duration(seconds: 30));
    cur.lastBanReason = 'prefer-next';
    banReasons.add('${cur.host}:prefer-next');
    VodProxyLog.log('ban host=${cur.host} reason=prefer-next n=1 cooldown=30s');
    return preferred?.host;
  }

  String describe({bool trafficOnly = true}) {
    final list = trafficOnly ? _hosts.where((h) => h.hasTraffic) : _hosts;
    if (list.isEmpty) return '-';
    return list
        .map((h) {
          final mbps = (h.emaBps * 8 / 1e6).toStringAsFixed(2);
          final ban = h.blacklistedUntil != null ? ' banned' : '';
          return '${h.host} ${mbps}Mbps ok=${h.successes} err=${h.errors}$ban';
        })
        .join(', ');
  }

  String sessionHostSummary() {
    final list = _hosts.where((h) => h.hasTraffic).toList();
    if (list.isEmpty) return '-';
    return list
        .map((h) {
          final avg = (h.emaBps * 8 / 1e6).toStringAsFixed(2);
          final peak = (h.peakBps * 8 / 1e6).toStringAsFixed(2);
          return '${h.host} bytes=${h.bytes} avg=${avg}Mbps peak=${peak}Mbps '
              'ok=${h.successes} err=${h.errors} ttfb=${h.avgTtfbMs.toStringAsFixed(0)}ms';
        })
        .join('; ');
  }

  bool get nearDeadline {
    if (_hosts.isEmpty) return false;
    final deadline = parsePlayurlDeadline(_hosts.first.url);
    if (deadline == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return deadline - now < 90;
  }

  int? get deadlineSec {
    if (_hosts.isEmpty) return null;
    return parsePlayurlDeadline(_hosts.first.url);
  }

  static List<String> buildCandidates(
    String primary, {
    Iterable<String> extras = const [],
  }) {
    return VideoUtils.candidateMediaUrls(primary, extras: extras);
  }
}
