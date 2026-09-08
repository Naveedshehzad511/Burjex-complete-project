#!/usr/bin/env bash
#
# B-Trader one-shot deploy: push source from this Mac, then rebuild + apply the
# Prisma schema + restart the stack on the target server. Safe for additive
# schema changes (prisma db push = no reset, no data loss). The CRM stack on
# the example server is untouched.
#
# Multi-server: each company deployment is a target file in infra/targets/
# (<name>.conf defining SERVER and optionally REMOTE_DIR). Default target is
# "example" so the historical `./deploy.sh` keeps working.
#
#   ./deploy.sh                     # deploy to the default target (example)
#   ./deploy.sh nova                # deploy to infra/targets/nova.conf
#   ./deploy.sh --no-sync           # default target, skip rsync
#   ./deploy.sh nova --no-sync      # named target, skip rsync
#
set -euo pipefail

cd "$(dirname "$0")"

TARGET="example"
NO_SYNC=0
for arg in "$@"; do
  case "$arg" in
    --no-sync) NO_SYNC=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *) TARGET="$arg" ;;
  esac
done

TARGET_FILE="infra/targets/$TARGET.conf"
if [[ ! -f "$TARGET_FILE" ]]; then
  echo "✗ no such target: $TARGET_FILE" >&2
  echo "  available: $(ls infra/targets/*.conf 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.conf//' | tr '\n' ' ')" >&2
  exit 1
fi

# Target config: SERVER (required, e.g. root@1.2.3.4), REMOTE_DIR (optional).
SERVER=""
REMOTE_DIR="/root/btrader"
# shellcheck disable=SC1090
source "$TARGET_FILE"
if [[ -z "$SERVER" ]]; then
  echo "✗ $TARGET_FILE must define SERVER=user@host" >&2
  exit 1
fi

COMPOSE="docker-compose.prod.yml"
echo "▶ target: $TARGET → $SERVER:$REMOTE_DIR"

if [[ "$NO_SYNC" -ne 1 ]]; then
  echo "▶ syncing source to $SERVER:$REMOTE_DIR ..."
  rsync -avz --delete \
    --exclude '.git' \
    --exclude 'node_modules' \
    --exclude 'flutter' \
    --exclude 'dist' \
    --exclude '**/build' \
    --exclude '.dart_tool' \
    --exclude 'infra/.env.prod' \
    --exclude 'infra/.env' \
    ./ "$SERVER:$REMOTE_DIR/"
fi

echo "▶ rebuild + migrate + restart on $SERVER ..."
ssh "$SERVER" "cd $REMOTE_DIR/infra \
  && docker compose -f $COMPOSE build \
  && docker compose -f $COMPOSE up -d btrader-postgres btrader-redis \
  && sleep 5 \
  && docker compose -f $COMPOSE run --rm btrader-gateway sh -lc 'cd /app/packages/db && npx prisma db push --skip-generate' \
  && docker compose -f $COMPOSE up -d \
  && docker compose -f $COMPOSE ps"

echo "✅ deploy complete → $TARGET"
