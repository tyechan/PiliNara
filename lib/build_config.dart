abstract final class BuildConfig {
  static const int versionCode = int.fromEnvironment(
    'pili.code',
    defaultValue: 2026101301,
  );
  static const String versionName = String.fromEnvironment(
    'pili.name',
    defaultValue: '2.1.6-20261013-vod-multiconn-proxy',
  );

  static const int buildTime = int.fromEnvironment('pili.time');
  static const String commitHash = String.fromEnvironment(
    'pili.hash',
    defaultValue: 'N/A',
  );

  static String get buildId {
    const hash = commitHash;
    if (hash.isEmpty || hash == 'N/A') {
      return '$versionName+$versionCode';
    }
    return '$versionName+$hash';
  }
}
