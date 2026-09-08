#!/usr/bin/env python3
"""Finalize .env.prod.ip + CREDENTIALS.txt on the VPS."""
from __future__ import annotations

import re
import secrets
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path("/opt/burjex")
ENV = ROOT / "deploy" / ".env.prod.ip"
CREDS = ROOT / "deploy" / "CREDENTIALS.txt"
IP = "187.127.215.195"


def set_key(text: str, key: str, value: str) -> str:
    pat = re.compile(rf"^{re.escape(key)}=.*$", re.M)
    if pat.search(text):
        return pat.sub(f"{key}={value}", text, count=1)
    return text + f"\n{key}={value}\n"


def get_key(text: str, key: str) -> str:
    m = re.search(rf"^{re.escape(key)}=(.*)$", text, re.M)
    return m.group(1).strip() if m else ""


def main() -> None:
    text = ENV.read_text(encoding="utf-8")
    enc = secrets.token_hex(16)  # exactly 32 chars
    text = set_key(text, "ENCRYPTION_KEY", enc)
    ENV.write_text(text, encoding="utf-8")
    ENV.chmod(0o600)

    leftovers = [
        line
        for line in text.splitlines()
        if not line.lstrip().startswith("#")
        and ("CHANGE_ME" in line or "YOUR_VPS_IP" in line)
    ]
    if leftovers:
        raise SystemExit("placeholders remain:\n" + "\n".join(leftovers))

    enc_len = len(get_key(text, "ENCRYPTION_KEY"))
    if enc_len != 32:
        raise SystemExit(f"ENCRYPTION_KEY length={enc_len}, expected 32")

    admin_pass = secrets.token_urlsafe(16)[:20]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    keys = [
        "DJANGO_SECRET_KEY",
        "JWT_SECRET",
        "JWT_REFRESH_SECRET",
        "ENCRYPTION_KEY",
        "CRM_INTEGRATION_KEY",
        "CRM_WEBHOOK_SECRET",
        "CRM_WEBHOOK_URL",
        "MT5_FEED_TOKEN",
        "BRIDGE_TOKEN",
        "POSTGRES_PASSWORD",
        "CRM_REDIS_PASSWORD",
        "BT_POSTGRES_PASSWORD",
        "BT_REDIS_PASSWORD",
    ]
    secret_lines = "\n".join(f"{k}={get_key(text, k)}" for k in keys)
    CREDS.write_text(
        f"""Burjex Prime — IP deployment credentials
Generated: {now}
Host: {IP}

=== URLs ===
CRM portal:     http://{IP}:8000/
CRM admin:      http://{IP}:8000/admin/
CRM health:     http://{IP}:8000/health/ready/
BTrader admin:  http://{IP}:4200/
BTrader REST:   http://{IP}:4100/v1
BTrader docs:   http://{IP}:4100/docs
BTrader WS:     ws://{IP}:4101
MT5 ingest:     http://{IP}:4300/ingest
MT5 health:     http://{IP}:4300/health
Web trader:     http://{IP}:4400/

=== CRM Django superuser ===
Username: admin
Password: {admin_pass}
Email: admin@burjex.local

=== Secrets ===
{secret_lines}

=== CRM to BTrader wiring ===
CRM Base URL internal: http://btrader-gateway:4100
Webhook URL: http://{IP}:8000/api/btrader/webhook/
Webhook secret: see CRM_WEBHOOK_SECRET
HMAC Key ID/Secret: create after BTrader seed

=== MT5 bridge Windows VPS ===
FeedUrl: http://{IP}:4300/ingest
BridgeApiUrl: http://{IP}:4100/v1
InpToken: see MT5_FEED_TOKEN
BridgeToken: see BRIDGE_TOKEN
BtTenantId: demo
""",
        encoding="utf-8",
    )
    CREDS.chmod(0o600)

    print(f"ENCRYPTION_KEY length={enc_len}")
    print(f"wrote {CREDS}")
    r = subprocess.run(
        [
            "docker",
            "compose",
            "-f",
            "deploy/docker-compose.ip.yml",
            "--env-file",
            "deploy/.env.prod.ip",
            "config",
        ],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(r.stderr)
        raise SystemExit(f"compose config failed: {r.returncode}")
    print("COMPOSE_OK")


if __name__ == "__main__":
    main()
