import 'logo_picker_types.dart';

/// Non-web fallback. Logo upload is a web-dashboard action (super admin manages
/// branding from admin.<domain>), so the mobile admin app doesn't pick files —
/// it returns null and the dialog keeps the paste-a-URL path. Kept dependency-
/// free on purpose so the admin APK doesn't pull a file-picker Android AAR.
Future<PickedLogo?> pickLogo() async => null;
