/// App-wide memory of CDN hosts that recently failed or crawled on video.
///
/// Video and audio probes of the same host can disagree (cosov is often
/// fine for audio and useless for video). Sessions consult this so a
/// host that just timed out on video is not ranked first again.
class VodHostHealth {
  VodHostHealth._();
  static final VodHostHealth instance = VodHostHealth._();

  static const Duration memory = Duration(minutes: 5);
  static const double slowTtfbMs = 1500;
  static const double slowThruMbps = 1.5;

  final Map<String, _HostMemory> _hosts = {};

  void resetForTest() => _hosts.clear();

  void noteVideoProbe(String host, {required double ttfbMs, required double thruMbps}) {
    final m = _ensure(host);
    m.videoAt = DateTime.now();
    m.videoTtfbMs = ttfbMs;
    m.videoThruMbps = thruMbps;
    if (ttfbMs >= slowTtfbMs || thruMbps < slowThruMbps) {
      m.videoSlowUntil = DateTime.now().add(memory);
    }
  }

  void noteBan(String host, {Duration cooldown = memory}) {
    _ensure(host).bannedUntil = DateTime.now().add(cooldown);
  }

  bool isVideoSlow(String host) {
    final m = _hosts[_key(host)];
    if (m?.videoSlowUntil == null) return false;
    if (!DateTime.now().isBefore(m!.videoSlowUntil!)) {
      m.videoSlowUntil = null;
      return false;
    }
    return true;
  }

  bool isBanned(String host) {
    final m = _hosts[_key(host)];
    if (m?.bannedUntil == null) return false;
    if (!DateTime.now().isBefore(m!.bannedUntil!)) {
      m.bannedUntil = null;
      return false;
    }
    return true;
  }

  _HostMemory _ensure(String host) =>
      _hosts.putIfAbsent(_key(host), _HostMemory.new);

  static String _key(String host) => host.toLowerCase();
}

class _HostMemory {
  DateTime? videoAt;
  double videoTtfbMs = 0;
  double videoThruMbps = 0;
  DateTime? videoSlowUntil;
  DateTime? bannedUntil;
}
