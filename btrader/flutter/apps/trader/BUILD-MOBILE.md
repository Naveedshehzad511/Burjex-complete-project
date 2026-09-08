# Building & distributing the B-Trader trader app (Android + iOS)

The Flutter app currently has `lib/` and `web/` only. This guide adds the native
Android/iOS platforms, configures white-label identity + networking, builds
release binaries with your API URLs baked in, and distributes them to testers.

Run everything from `flutter/apps/trader/`.

---

## 0. Prerequisites

- **Android:** Android Studio (or just the Android SDK + an emulator/device). Run `flutter doctor` — the "Android toolchain" line must be ✓.
- **iOS (Mac only):** Xcode from the App Store. To install on a **real iPhone** or use TestFlight you need an **Apple Developer account ($99/yr)**. The iOS *simulator* works without it.
- Confirm: `flutter doctor`

---

## 1. Generate the native platforms

```bash
cd ~/B-Trader/B-Trader/flutter/apps/trader
flutter create --org io.btrader --platforms=android,ios .
```

This adds `android/` and `ios/` without touching your `lib/`. Default package
becomes `io.btrader.btrader_trader` — adjust below if you want.

Then fetch packages:
```bash
flutter pub get
```

---

## 2. White-label identity (app name + bundle id)

**App display name**

- Android — `android/app/src/main/AndroidManifest.xml`, in the `<application>` tag:
  ```xml
  android:label="B-Trader"
  ```
- iOS — `ios/Runner/Info.plist`:
  ```xml
  <key>CFBundleDisplayName</key>
  <string>B-Trader</string>
  ```

**Bundle id / package** (optional — only if you want something other than the `--org` default)

- Android — `android/app/build.gradle` (or `build.gradle.kts`): set
  `applicationId "io.btrader.app"`
- iOS — open `ios/Runner.xcworkspace` in Xcode → Runner target → Signing &
  Capabilities → set **Bundle Identifier** = `io.btrader.app` and pick your Team.

> Per-broker white-label: each broker brand gets its own `applicationId` /
> bundle id + name + icon, but the same code. The app pulls colors/logo at
> runtime from `/v1/public/branding`, so only identity + icon differ per build.

---

## 3. Networking config

Pick based on what the app will talk to:

### A) Production (Hetzner over HTTPS) — nothing to configure
`config/prod.json` uses `https://`/`wss://`. Android and iOS allow secure
traffic by default. Skip to step 4.

### B) LAN testing (your Mac's backend over plain HTTP) — allow cleartext
`config/dev.json` uses `http://`/`ws://`, which both platforms block by default.
For **testing only**, allow it:

**Android** — `android/app/src/main/AndroidManifest.xml`:
1. Above `<application>`, ensure the INTERNET permission is present (required for release builds):
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   ```
2. In the `<application>` tag add:
   ```xml
   android:usesCleartextTraffic="true"
   ```

**iOS** — `ios/Runner/Info.plist`, add inside the top `<dict>`:
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>
```

> Remove both cleartext exceptions before any public/production release —
> production uses HTTPS/WSS and doesn't need them.

**Find your Mac's LAN IP** and put it in `config/dev.json`:
```bash
ipconfig getifaddr en0   # Wi-Fi (try en1 if blank)
```
Your phone must be on the **same Wi-Fi**, and macOS firewall must allow
incoming connections on 4100/4101.

---

## 4. Build

API URLs are baked in via `--dart-define-from-file` (no need to retype them).

**Run on a connected device/emulator (debug):**
```bash
flutter run --dart-define-from-file=config/dev.json
```

**Android APK** (shareable file, quickest for testers):
```bash
flutter build apk --release --dart-define-from-file=config/dev.json
# output: build/app/outputs/flutter-apk/app-release.apk
```

**Android App Bundle** (for Google Play):
```bash
flutter build appbundle --release --dart-define-from-file=config/prod.json
# output: build/app/outputs/bundle/release/app-release.aab
```

**iOS** (needs Xcode signing + Apple Developer):
```bash
flutter build ipa --release --dart-define-from-file=config/prod.json
# then upload build/ios/ipa/*.ipa via Xcode Organizer or Transporter
```

---

## 5. Distribute to testers

**Quick — Android APK direct:** send `app-release.apk` (AirDrop, Drive, link).
Tester enables "install unknown apps" and opens it. Zero setup.

**Recommended — Firebase App Distribution (Android + iOS, free):**
```bash
npm i -g firebase-tools
firebase login

# Android
firebase appdistribution:distribute build/app/outputs/flutter-apk/app-release.apk \
  --app <FIREBASE_ANDROID_APP_ID> --groups "testers"

# iOS (after building the .ipa)
firebase appdistribution:distribute build/ios/ipa/btrader_trader.ipa \
  --app <FIREBASE_IOS_APP_ID> --groups "testers"
```
Create a Firebase project, register the Android/iOS app to get the App IDs, add
testers to a "testers" group. Testers get an email + install link.

**Google Play internal testing (Android):** upload the `.aab` to Play Console →
Testing → Internal testing → add up to 100 testers.

**TestFlight (iOS):** upload the `.ipa` to App Store Connect → TestFlight; needs
the Apple Developer account.

---

## 6. App icon (optional polish)

Default is the Flutter logo. To set the B-Trader icon per brand:
```bash
flutter pub add dev:flutter_launcher_icons
```
Add a `flutter_launcher_icons` block to `pubspec.yaml` pointing at a 1024×1024
PNG, then `dart run flutter_launcher_icons`.

---

## Quick path for your first device test

```bash
cd ~/B-Trader/B-Trader/flutter/apps/trader
flutter create --org io.btrader --platforms=android,ios .
flutter pub get
# edit config/dev.json with your Mac's LAN IP (ipconfig getifaddr en0)
# add the Android cleartext + INTERNET lines (step 3B)
flutter build apk --release --dart-define-from-file=config/dev.json
# share build/app/outputs/flutter-apk/app-release.apk to your Android phone
```
Sign in: `trader@demofx.com` / `Trader123!`.
