# Firebase drop-in slots (no invented keys)

The original Android `google-services.json` and iOS `GoogleService-Info.plist` are **not** in compiled `web/portal/main.dart.js`. Do not fabricate a Google project id, `google_app_id`, `gcm_sender_id`, or API key.

## What Naveed should do

1. Open [Firebase Console](https://console.firebase.google.com/) for the **real** Burjex / Burjex Prime project (or create one if none exists).
2. Add apps with these exact application ids (they match `flutter create --org net.burjexprime`):
   - Android package: `net.burjexprime.forexten_mobile`
   - iOS bundle: `net.burjexprime.forexten_mobile`
3. Download the console files and place them here:

| Slot | Path |
|---|---|
| Android | `forexten_mobile/android/app/google-services.json` |
| iOS | `forexten_mobile/ios/Runner/GoogleService-Info.plist` |

Those two paths are gitignored so secrets stay off GitHub. Example **shape** files (tokens only, not real keys) live next to this README.

4. Enable **Cloud Messaging**.
5. In `android/settings.gradle.kts` add `id("com.google.gms.google-services") version "4.4.2" apply false`, then apply the plugin from `android/app/build.gradle.kts` when the JSON exists (comments are already in that file).
6. Add `firebase_core` + `firebase_messaging` to `pubspec.yaml` and implement `PushService.init()`:
   - `Firebase.initializeApp()`
   - `FirebaseMessaging.instance.getToken()`
   - `POST https://crm.burjexprime.net/api/v1/devices/` with `{ "fcm_token", "platform" }` once that CRM route exists
7. Use that token for **deposit / withdrawal status** pushes.

Until the real files exist, `PushService` is a no-op and the trading app still talks to live `/v1` + CRM.
