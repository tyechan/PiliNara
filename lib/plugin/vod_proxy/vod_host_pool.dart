import 'package:PiliPlus/plugin/vod_proxy/vod_range.dart';
import 'package:PiliPlus/utils/video_utils.dart';

class VodHostStat {
  VodHostStat(this.url) : host = Uri.tryParse(url)?.host ?? url;

  final String url;
  final String host;
  double emaBps = 0;
  int successes = 0;
  int errors = 0;
  DateTime? blacklistedUntil;

  bool get isBlacklisted {
    final until = blacklistedUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    blacklistedUntil = null;
    return false;
  }
}

/// Ranked candidate URLs (same path/query, different CDN hosts).
class VodHostPool {
  VodHostPool(List<String> urls) : _hosts = _unique(urls);

  final List<VodHostStat> _hosts;
  int _rotate = 0;

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

  List<VodHostStat> get hosts => List.unmodifiable(_hosts);

  List<VodHostStat> get available =>
      _hosts.where((h) => !h.isBlacklisted).toList();

  VodHostStat? get preferred {
    final open = available;
    if (open.isEmpty) return _hosts.isEmpty ? null : _hosts.first;
    open.sort((a, b) {
      final speed = b.emaBps.compareTo(a.emaBps);
      if (speed != 0) return speed;
      return a.errors.compareTo(b.errors);
    });
    return open.first;
  }

  /// Next URL to try: fastest host, then round-robin among unused.
  String? pickUrl({String? avoidHost}) {
    final open = available;
    if (open.isEmpty) {
      if (_hosts.isEmpty) return null;
      return _hosts[_rotate++ % _hosts.length].url;
    }
    final usable = avoidHost == null
        ? open
        : open.where((h) => h.host != avoidHost).toList();
    final pool = usable.isEmpty ? open : usable;
    if (pool.any((h) => h.emaBps > 0)) {
      pool.sort((a, b) {
        final speed = b.emaBps.compareTo(a.emaBps);
        if (speed != 0) return speed;
        return a.errors.compareTo(b.errors);
      });
    }
    // Keep the original host first until something is actually faster.
    return pool.first.url;
  }

  VodHostStat? _find(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    for (final h in _hosts) {
      if (h.host == host) return h;
    }
    return null;
  }

  void recordSuccess(String url, {required int bytes, required int elapsedMs}) {
    final stat = _find(url);
    if (stat == null) return;
    stat.successes++;
    if (elapsedMs > 0 && bytes > 0) {
      final bps = bytes * 1000 / elapsedMs;
      stat.emaBps = stat.emaBps <= 0 ? bps : (stat.emaBps * 0.7 + bps * 0.3);
    }
  }

  void recordFailure(
    String url, {
    required String reason,
    Duration ban = const Duration(seconds: 15),
  }) {
    final stat = _find(url);
    if (stat == null) return;
    stat.errors++;
    stat.blacklistedUntil = DateTime.now().add(ban);
  }

  /// Stall recovery: ban the current preferred host so the next fetch moves.
  String? preferNext() {
    final cur = preferred;
    if (cur == null) return null;
    cur.blacklistedUntil = DateTime.now().add(const Duration(seconds: 30));
    return preferred?.host;
  }

  String describe() {
    return _hosts
        .map((h) {
          final mbps = (h.emaBps * 8 / 1e6).toStringAsFixed(2);
          final ban = h.isBlacklisted ? ' banned' : '';
          return '${h.host} ${mbps}Mbps ok=${h.successes} err=${h.errors}$ban';
        })
        .join(', ');
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
