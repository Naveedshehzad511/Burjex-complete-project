#!/usr/bin/env bash
#
# Build a white-labelled ADMIN WEB bundle for one tenant. Regenerates the web
# favicon/PWA icons from the tenant's icon, then builds with the tenant config.
# Output: build/web  (rsync it to that tenant's admin host).
#
#   ./build-admin-web.sh <tenant>
#   ./build-admin-web.sh broker
#
set -euo pipefail
cd "$(dirname "$0")"

TENANT="${1:?usage: build-admin-web.sh <tenant>}"
CONFIG="config/${TENANT}.json"
ICONS="flutter_launcher_icons-${TENANT}.yaml"
[[ -f "$CONFIG" ]] || { echo "✗ missing $CONFIG"; exit 1; }

if [[ -f "$ICONS" ]]; then
  echo "▶ [$TENANT] generating web favicon/PWA icons ..."
  dart run flutter_launcher_icons -f "$ICONS"
fi

echo "▶ [$TENANT] building admin web ..."
flutter build web --release --dart-define-from-file="$CONFIG"

echo "✅ [$TENANT] → build/web (rsync to the tenant's admin host)"
echo "   NOTE: web icons were regenerated. Reset with 'dart run flutter_launcher_icons'"
echo "   before a Example build."
