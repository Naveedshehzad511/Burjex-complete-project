#!/usr/bin/env bash
#
# Build a white-labelled ADMIN APK for one tenant. Same model as the trader
# app's build-trader-apk.sh:
#   1. runtime config → config/<tenant>.json (API_BASE, WS_URL, TENANT)
#   2. launcher icon   → icons-<tenant>.yaml (regenerated here)
#   3. app id + label  → -Papp.id / -Papp.label to Gradle
# Interior branding (name, logo, colors) comes live from the tenant branding API.
#
# ⚠️ Icon config file naming: do NOT name this file
# `flutter_launcher_icons-<tenant>.yaml` — the flutter_launcher_icons package
# auto-detects ANY file matching that exact pattern in this directory as an
# Android product "flavor" and silently ignores the -f/--file argument,
# writing icons to android/app/src/<tenant>/res/ instead of src/main/res/. We
# don't declare Gradle product flavors, so that source set is never compiled
# in — the APK silently ships whatever icon was last in src/main/res (i.e.
# leftover Example) even though this script reports success. Hence
# `icons-<tenant>.yaml`, which doesn't match that regex.
#
#   ./build-admin-apk.sh <tenant> <app.id> "<App Label>"
#   ./build-admin-apk.sh broker com.broker.admin "Broker Admin"
#
set -euo pipefail
cd "$(dirname "$0")"

TENANT="${1:?usage: build-admin-apk.sh <tenant> <app.id> <App Label>}"
APP_ID="${2:?need an Android application id, e.g. com.broker.admin}"
APP_LABEL="${3:?need a home-screen label, e.g. \"Broker Admin\"}"

CONFIG="config/${TENANT}.json"
ICONS="icons-${TENANT}.yaml"
[[ -f "$CONFIG" ]] || { echo "✗ missing $CONFIG"; exit 1; }
[[ -f "$ICONS"  ]] || { echo "✗ missing $ICONS"; exit 1; }

echo "▶ [$TENANT] generating admin launcher icons ..."
dart run flutter_launcher_icons -f "$ICONS"

# Guard: see build-trader-apk.sh for the full explanation of why a stray
# flutter_launcher_icons-*.yaml silently breaks icon generation via Android
# flavor auto-detection.
if compgen -G "flutter_launcher_icons-*.yaml" > /dev/null; then
  echo "✗ found a flutter_launcher_icons-*.yaml file — rename it to icons-<tenant>.yaml" >&2
  echo "  and remove any android/app/src/<tenant>/ it may have created." >&2
  exit 1
fi

echo "▶ [$TENANT] clean build (avoids any stale Gradle resource cache) ..."
flutter clean >/dev/null

echo "▶ [$TENANT] building admin APK (id=$APP_ID label=$APP_LABEL) ..."
flutter build apk --release \
  --dart-define-from-file="$CONFIG" \
  -Papp.id="$APP_ID" \
  -Papp.label="$APP_LABEL"

DEST="build/app/outputs/flutter-apk/${TENANT}-admin-release.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$DEST"
echo "✅ [$TENANT] → $DEST"
echo "   NOTE: launcher icons were regenerated into android/. Reset with"
echo "   'dart run flutter_launcher_icons' (Example default) before a Example build."
