#!/usr/bin/env bash
#
# Build a white-labelled trader APK for one tenant. Ties together the three
# things that must differ per tenant:
#   1. runtime config  → config/<tenant>.json  (API_BASE, WS_URL, TENANT)
#   2. launcher icon    → icons-<tenant>.yaml (regenerated here)
#   3. app id + label   → passed to Gradle as -Papp.id / -Papp.label
#
# The interior branding (app name, logo, colors shown IN the app) already comes
# live from the tenant's branding API — this script only handles the parts that
# are baked into the Android package at build time.
#
# ⚠️ Icon config file naming: do NOT name this file
# `flutter_launcher_icons-<tenant>.yaml` — the flutter_launcher_icons package
# auto-detects ANY file matching that exact pattern in this directory as an
# Android product "flavor" and silently ignores the -f/--file argument,
# writing icons to android/app/src/<tenant>/res/ instead of src/main/res/.
# Since we don't declare Gradle product flavors, that source set is never
# compiled in — the APK silently keeps whatever icon was last written to
# src/main/res (i.e. leftover Example) even though this script "succeeds".
# Hence the `icons-<tenant>.yaml` name below, which doesn't match that regex.
#
#   ./build-trader-apk.sh <tenant> <app.id> "<App Label>"
#   ./build-trader-apk.sh broker com.broker.trader "Broker"
#
set -euo pipefail
cd "$(dirname "$0")"

TENANT="${1:?usage: build-trader-apk.sh <tenant> <app.id> <App Label>}"
APP_ID="${2:?need an Android application id, e.g. com.broker.trader}"
APP_LABEL="${3:?need a home-screen label, e.g. Broker}"

CONFIG="config/${TENANT}.json"
ICONS="icons-${TENANT}.yaml"
[[ -f "$CONFIG" ]] || { echo "✗ missing $CONFIG (API_BASE/WS_URL/TENANT)"; exit 1; }
[[ -f "$ICONS"  ]] || { echo "✗ missing $ICONS (launcher icon config)"; exit 1; }

echo "▶ [$TENANT] generating launcher icons ..."
dart run flutter_launcher_icons -f "$ICONS"

# Guard: any file matching flutter_launcher_icons-*.yaml in this directory
# makes the tool auto-detect Android "flavors" and silently write icons to
# android/app/src/<name>/res/ instead of src/main/res/ — ignoring -f entirely.
# We don't declare Gradle product flavors, so that source set never compiles
# in, and the build would ship whatever icon was last in src/main/res without
# any error. Fail loudly instead of shipping a wrong icon.
if compgen -G "flutter_launcher_icons-*.yaml" > /dev/null; then
  echo "✗ found a flutter_launcher_icons-*.yaml file — this triggers the package's" >&2
  echo "  flavor auto-detection and silently breaks -f/--file. Rename it (this repo" >&2
  echo "  convention is icons-<tenant>.yaml) and remove any android/app/src/<tenant>/" >&2
  echo "  it may have created." >&2
  exit 1
fi

echo "▶ [$TENANT] clean build (avoids any stale Gradle resource cache) ..."
flutter clean >/dev/null

echo "▶ [$TENANT] building APK (id=$APP_ID label=$APP_LABEL) ..."
flutter build apk --release \
  --dart-define-from-file="$CONFIG" \
  -Papp.id="$APP_ID" \
  -Papp.label="$APP_LABEL"

OUT="build/app/outputs/flutter-apk/app-release.apk"
DEST="build/app/outputs/flutter-apk/${TENANT}-release.apk"
cp "$OUT" "$DEST"
echo "✅ [$TENANT] → $DEST"
echo "   NOTE: launcher icons were regenerated into android/. Reset with"
echo "   'dart run flutter_launcher_icons' (Example default) before a Example build."
