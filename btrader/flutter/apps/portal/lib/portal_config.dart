/// Live client portal. This APK hosts the same Trade+ UI that
/// https://portal.burjexprime.net serves: Home / Quotes / Chart / Trade / History.
/// Override with `--dart-define=PORTAL_URL=...`.
class PortalConfig {
  PortalConfig._();

  static const String url = String.fromEnvironment(
    'PORTAL_URL',
    defaultValue: 'https://portal.burjexprime.net',
  );

  static const String title = String.fromEnvironment(
    'APP_TITLE',
    defaultValue: 'Burjex Prime',
  );

  static Uri get uri => Uri.parse(url);
}
