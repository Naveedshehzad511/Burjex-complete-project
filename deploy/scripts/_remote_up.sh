#!/bin/bash
set -euo pipefail
mkdir -p /opt/burjex
cd /opt/burjex
tar -xzf /tmp/burjex_deploy.tgz
mkdir -p /opt/burjex/web/admin /opt/burjex/web/trader
python3 /tmp/_remote_setup.py
ufw allow 22/tcp || true
ufw allow 8000/tcp || true
ufw allow 4100/tcp || true
ufw allow 4101/tcp || true
ufw allow 4200/tcp || true
ufw allow 4300/tcp || true
ufw allow 4400/tcp || true
yes | ufw enable || true
cd /opt/burjex
docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip up -d --build
echo "==== CONTAINERS ===="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "==== HEALTH ===="
sleep 15
for p in 8000 4100 4200 4300 4400; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "http://127.0.0.1:${p}/" || echo ERR)
  echo "port ${p} -> ${code}"
done
curl -s -o /dev/null -w "crm health %{http_code}\n" --max-time 10 http://127.0.0.1:8000/health/ready/ || true
docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip exec -T crm-web python manage.py migrate --noinput || true
docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip exec -T btrader-gateway npx prisma db push || true
echo DONE_REMOTE
