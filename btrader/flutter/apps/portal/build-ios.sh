#!/usr/bin/env bash
# Builds the Burjex Prime iOS app for TestFlight / the App Store, the same way the Android .aab is built.
#
#   cd btrader/flutter/apps/portal
#   ./build-ios.sh                 # version 1.0.3, build number = today+hour (e.g. 26102014)
#   ./build-ios.sh 1.0.3 26102001  # explicit version and build number (must be higher than the last upload)
#
# Do NOT archive from Xcode (Product > Archive) for a release: Xcode passes none of the production settings
# (config/burjexprime.json), and an old checkout misses the bundled fonts. This script always builds the
# latest code with those settings and refuses to finish if the result is missing either.
#
# One-time on the Mac: Xcode installed and signed in with the Apple account; open ios/Runner.xcworkspace once,
# Runner > Signing & Capabilities > pick the Team (Automatic signing). Then only this script is needed.
set -euo pipefail
cd "$(dirname "$0")"

NAME="${1:-1.0.3}"
NUMBER="${2:-$(date +%y%m%d%H)}"
CONFIG="config/burjexprime.json"
APP="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app"
ASSETS="$APP/Frameworks/App.framework/flutter_assets"

echo "▶ checking the code is the latest main ..."
git fetch -q origin main || true
if [[ -n "$(git rev-list HEAD..origin/main 2>/dev/null)" ]]; then
  echo "✗ this checkout is behind origin/main - run: git pull" >&2
  exit 1
fi
echo "  commit $(git rev-parse --short HEAD)"

echo "▶ clean build (no stale fonts / assets / settings) ..."
flutter clean >/dev/null
flutter pub get >/dev/null

echo "▶ building the IPA $NAME ($NUMBER) against production ..."
flutter build ipa --release \
  --dart-define-from-file="$CONFIG" \
  --build-name="$NAME" \
  --build-number="$NUMBER"

echo "▶ checking the build ..."
fail=0
for w in Regular Medium SemiBold Bold ExtraBold; do
  if [[ ! -f "$ASSETS/packages/btrader_core/fonts/Roboto-$w.ttf" ]]; then
    echo "✗ font Roboto-$w.ttf is missing from the app (text would look bold on iPhone)" >&2
    fail=1
  fi
done
if ! grep -aq "portal.burjexprime.net" "$APP/Frameworks/App.framework/App"; then
  echo "✗ the production server address is not in the app (Quotes / Chart / Trade / History would not load)" >&2
  fail=1
fi
[[ "$fail" -eq 0 ]] || exit 1

IPA=$(ls build/ios/ipa/*.ipa)
echo "✅ $IPA  (version $NAME, build $NUMBER, fonts and production server checked)"
echo
echo "Upload it to TestFlight, one of:"
echo "  - the Transporter app (Mac App Store): drag the .ipa in, Deliver"
echo "  - Xcode: open build/ios/archive/Runner.xcarchive, then Distribute App > App Store Connect > Upload"
