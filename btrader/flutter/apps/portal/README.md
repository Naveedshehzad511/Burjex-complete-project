# Burjex Prime portal APK

Android app for the live client portal: **Home / Quotes / Chart / Trade / History**.

This is **not** the deleted Markets / Portfolio / Settings trader app. The Trade+
Dart source is not in this repo (`web/portal` is the compiled bundle), so the APK
opens `https://portal.burjexprime.net` and keeps cashback, KYC, and the five-tab
nav that is already live.

```bash
./build-portal-apk.sh
# → build/app/outputs/flutter-apk/burjex-prime-portal-release.apk
```
