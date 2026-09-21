#!/usr/bin/env bash
# Burjex Prime client portal APK (Home / Quotes / Chart / Trade / History).
# Loads the live Trade+ portal — not the deleted Markets/Portfolio trader app.
#
#   ./build-portal-apk.sh
#   ./build-portal-apk.sh https://portal.burjexprime.net
set -euo pipefail
cd "$(dirname "$0")"

PORTAL_URL="${1:-https://portal.burjexprime.net}"
APP_ID="${APP_ID:-net.burjexprime.portal}"
APP_LABEL="${APP_LABEL:-Burjex Prime}"

echo "▶ generating launcher icons ..."
dart run flutter_launcher_icons

echo "▶ building $APP_LABEL APK → $PORTAL_URL"
flutter build apk --release \
  --dart-define=PORTAL_URL="$PORTAL_URL" \
  --dart-define=APP_TITLE="$APP_LABEL"

DEST="build/app/outputs/flutter-apk/burjex-prime-portal-release.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$DEST"
echo "✅ $DEST"
