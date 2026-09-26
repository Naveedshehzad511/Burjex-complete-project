/// Deposit / withdrawal push hook.
///
/// Original `google-services.json` / `GoogleService-Info.plist` cannot be
/// recovered from compiled portal JS. Until Naveed drops the real files into
/// the slots documented in `firebase/README.md`, this stays a no-op so the
/// app still builds and talks to live `/v1` + CRM.
class PushService {
  PushService._();

  static bool get configured => false;

  static Future<void> init() async {
    // Slot: Firebase.initializeApp() after real google-services files exist.
    // Slot: FirebaseMessaging.instance.getToken() then POST to CRM:
    //   https://crm.burjexprime.net/api/v1/devices/
    //   body: { "fcm_token": token, "platform": "android"|"ios" }
    // Use that token for deposit / withdrawal status notifications.
  }

  static Future<void> syncToken({String? crmToken}) async {
    if (!configured || crmToken == null || crmToken.isEmpty) return;
  }
}
