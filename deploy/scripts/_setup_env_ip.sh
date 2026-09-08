#!/bin/bash
set -euo pipefail
cd /opt/burjex

IP=187.127.215.195

DJANGO_SECRET=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
JWT_REFRESH=$(openssl rand -hex 32)
CRM_WEBHOOK_SECRET=$(openssl rand -hex 32)
CRM_INTEGRATION_KEY=$(openssl rand -hex 32)
MT5_FEED_TOKEN=$(openssl rand -hex 24)
BRIDGE_TOKEN=$(openssl rand -hex 24)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
CRM_REDIS_PASSWORD=$(openssl rand -hex 16)
BT_POSTGRES_PASSWORD=$(openssl rand -hex 16)
BT_REDIS_PASSWORD=$(openssl rand -hex 16)
ENCRYPTION_KEY=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
CRM_ADMIN_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)

cp deploy/.env.prod.ip.example deploy/.env.prod.ip
sed -i "s/YOUR_VPS_IP/${IP}/g" deploy/.env.prod.ip

# Replace shared password placeholders first (appear in URLs)
sed -i "s/CHANGE_ME_strong_redis_password/${CRM_REDIS_PASSWORD}/g" deploy/.env.prod.ip
sed -i "s/CHANGE_ME_strong_db_password/${BT_POSTGRES_PASSWORD}/g" deploy/.env.prod.ip

# Per-key replacements (unique secrets)
sed -i "s/^DJANGO_SECRET_KEY=.*/DJANGO_SECRET_KEY=${DJANGO_SECRET}/" deploy/.env.prod.ip
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" deploy/.env.prod.ip
sed -i "s/^CRM_REDIS_PASSWORD=.*/CRM_REDIS_PASSWORD=${CRM_REDIS_PASSWORD}/" deploy/.env.prod.ip
sed -i "s/^BT_POSTGRES_PASSWORD=.*/BT_POSTGRES_PASSWORD=${BT_POSTGRES_PASSWORD}/" deploy/.env.prod.ip
sed -i "s/^BT_REDIS_PASSWORD=.*/BT_REDIS_PASSWORD=${BT_REDIS_PASSWORD}/" deploy/.env.prod.ip
sed -i "s/^JWT_SECRET=.*/JWT_SECRET=${JWT_SECRET}/" deploy/.env.prod.ip
sed -i "s/^JWT_REFRESH_SECRET=.*/JWT_REFRESH_SECRET=${JWT_REFRESH}/" deploy/.env.prod.ip
sed -i "s/^ENCRYPTION_KEY=.*/ENCRYPTION_KEY=${ENCRYPTION_KEY}/" deploy/.env.prod.ip
sed -i "s/^CRM_INTEGRATION_KEY=.*/CRM_INTEGRATION_KEY=${CRM_INTEGRATION_KEY}/" deploy/.env.prod.ip
sed -i "s/^CRM_WEBHOOK_SECRET=.*/CRM_WEBHOOK_SECRET=${CRM_WEBHOOK_SECRET}/" deploy/.env.prod.ip
sed -i "s/^MT5_FEED_TOKEN=.*/MT5_FEED_TOKEN=${MT5_FEED_TOKEN}/" deploy/.env.prod.ip
sed -i "s/^BRIDGE_TOKEN=.*/BRIDGE_TOKEN=${BRIDGE_TOKEN}/" deploy/.env.prod.ip

# Fail if any CHANGE_ME remains
if grep -qE 'CHANGE_ME|YOUR_VPS_IP' deploy/.env.prod.ip; then
  echo "ERROR: placeholders remain:" >&2
  grep -nE 'CHANGE_ME|YOUR_VPS_IP' deploy/.env.prod.ip >&2
  exit 1
fi

chmod 600 deploy/.env.prod.ip

echo "=== leftover placeholders ==="
grep -nE 'CHANGE_ME|YOUR_VPS_IP' deploy/.env.prod.ip || echo "NONE — clean"
echo "=== key IP / URL lines ==="
grep -E '^(PUBLIC_HOST|DJANGO_ALLOWED_HOSTS|DJANGO_CSRF_TRUSTED_ORIGINS|SITE_BASE_URL|CRM_WEBHOOK_URL|CORS_ALLOWED_ORIGINS)=' deploy/.env.prod.ip
echo "=== ENCRYPTION_KEY length ==="
awk -F= '/^ENCRYPTION_KEY=/{print length($2)}' deploy/.env.prod.ip

# Persist admin password for later createsuperuser
cat > deploy/CREDENTIALS.txt <<EOF
Burjex Prime — IP deployment credentials
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Host: ${IP}

=== URLs ===
CRM portal:     http://${IP}:8000/
CRM admin:      http://${IP}:8000/admin/
CRM health:     http://${IP}:8000/health/ready/
BTrader admin:  http://${IP}:4200/
BTrader REST:   http://${IP}:4100/v1
BTrader docs:   http://${IP}:4100/docs
BTrader WS:     ws://${IP}:4101
MT5 ingest:     http://${IP}:4300/ingest
MT5 health:     http://${IP}:4300/health
Web trader:     http://${IP}:4400/

=== CRM Django superuser ===
Username: admin
Password: ${CRM_ADMIN_PASS}
Email: admin@burjex.local

=== Secrets ===
DJANGO_SECRET_KEY=${DJANGO_SECRET}
JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
CRM_INTEGRATION_KEY=${CRM_INTEGRATION_KEY}
CRM_WEBHOOK_SECRET=${CRM_WEBHOOK_SECRET}
CRM_WEBHOOK_URL=http://${IP}:8000/api/btrader/webhook/
MT5_FEED_TOKEN=${MT5_FEED_TOKEN}
BRIDGE_TOKEN=${BRIDGE_TOKEN}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
CRM_REDIS_PASSWORD=${CRM_REDIS_PASSWORD}
BT_POSTGRES_PASSWORD=${BT_POSTGRES_PASSWORD}
BT_REDIS_PASSWORD=${BT_REDIS_PASSWORD}

=== CRM to BTrader wiring ===
CRM Base URL internal: http://btrader-gateway:4100
Webhook URL: http://${IP}:8000/api/btrader/webhook/
Webhook secret: see CRM_WEBHOOK_SECRET
HMAC Key ID/Secret: create after BTrader seed

=== MT5 bridge Windows VPS ===
FeedUrl: http://${IP}:4300/ingest
BridgeApiUrl: http://${IP}:4100/v1
InpToken: see MT5_FEED_TOKEN
BridgeToken: see BRIDGE_TOKEN
BtTenantId: demo
EOF
chmod 600 deploy/CREDENTIALS.txt
ls -la deploy/.env.prod.ip deploy/CREDENTIALS.txt
echo ENV_READY
