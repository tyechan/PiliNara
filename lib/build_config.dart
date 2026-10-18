abstract final class BuildConfig {
  static const int versionCode = int.fromEnvironment(
    'pili.code',
    defaultValue: 2026101801,
  );
  static const String versionName = String.fromEnvironment(
    'pili.name',
    defaultValue: '2.1.6-1017d',
  );

  static const int buildTime = int.fromEnvironment('pili.time');
  static const String commitHash = String.fromEnvironment(
    'pili.hash',
    defaultValue: 'N/A',
  );

  static String get shortHash {
    const hash = commitHash;
    if (hash.isEmpty || hash == 'N/A') return 'dev';
    return hash.length <= 7 ? hash : hash.substring(0, 7);
  }

  /// One-line About label, e.g. `2.1.6 · 1016 · 7e718a6`.
  static String get displayVersion {
    final parts = versionName.split('-');
    final base = parts.isNotEmpty ? parts.first : versionName;
    final stamp = parts.length > 1
        ? parts[1].replaceAll(RegExp(r'[^0-9]'), '')
        : '';
    if (stamp.isEmpty) return '$base · $shortHash';
    return '$base · $stamp · $shortHash';
  }

  static String get buildId {
    const hash = commitHash;
    if (hash.isEmpty || hash == 'N/A') {
      return '$versionName+$versionCode';
    }
    return '$versionName+$hash';
  }
}
