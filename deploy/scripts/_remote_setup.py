#!/usr/bin/env python3
"""Fill deploy/.env.prod.ip and CREDENTIALS.txt on the VPS (IP mode)."""
from __future__ import annotations

import pathlib
import secrets
import shutil


ROOT = pathlib.Path("/opt/burjex")
DEPLOY = ROOT / "deploy"
EXAMPLE = DEPLOY / ".env.prod.ip.example"
ENV = DEPLOY / ".env.prod.ip"
CRED = DEPLOY / "CREDENTIALS.txt"
IP = "187.127.215.195"


def hx(n: int = 32) -> str:
    return secrets.token_hex(n)


def main() -> None:
    if not EXAMPLE.exists():
        raise SystemExit(f"missing {EXAMPLE}")

    secrets_map = {
        "DJANGO_SECRET_KEY": hx(32),
        "POSTGRES_PASSWORD": hx(24),
        "CRM_REDIS_PASSWORD": hx(24),
        "BT_POSTGRES_PASSWORD": hx(24),
        "BT_REDIS_PASSWORD": hx(24),
        "JWT_SECRET": hx(32),
        "JWT_REFRESH_SECRET": hx(32),
        "ENCRYPTION_KEY": secrets.token_hex(16),  # exactly 32 chars
        "CRM_INTEGRATION_KEY": hx(32),
        "CRM_WEBHOOK_SECRET": hx(32),
        "MT5_FEED_TOKEN": hx(24),
        "BRIDGE_TOKEN": hx(24),
    }

    text = EXAMPLE.read_text(encoding="utf-8").replace("YOUR_VPS_IP", IP)
    out_lines: list[str] = []
    for line in text.splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            out_lines.append(line)
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key in secrets_map:
            out_lines.append(f"{key}={secrets_map[key]}")
            continue
        if key in ("REDIS_URL", "CELERY_BROKER_URL", "CHANNELS_REDIS_URL"):
            # redis://:PASSWORD@host:port/db
            prefix, _, rest = val.partition("@")
            # prefix like redis://:CHANGE_ME...
            out_lines.append(
                f"{key}=redis://:{secrets_map['CRM_REDIS_PASSWORD']}@{rest}"
            )
            continue
        if key == "DATABASE_URL":
            out_lines.append(
                "DATABASE_URL=postgresql://btrader:"
                f"{secrets_map['BT_POSTGRES_PASSWORD']}"
                "@btrader-postgres:5432/btrader?schema=public"
            )
            continue
        out_lines.append(line)

    ENV.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    ENV.chmod(0o600)

    cred_body = (
        "Burjex VPS credentials — keep private (chmod 600)\n"
        f"PUBLIC_IP={IP}\n"
        f"DJANGO_SECRET_KEY={secrets_map['DJANGO_SECRET_KEY']}\n"
        f"POSTGRES_PASSWORD={secrets_map['POSTGRES_PASSWORD']}\n"
        f"CRM_REDIS_PASSWORD={secrets_map['CRM_REDIS_PASSWORD']}\n"
        f"BT_POSTGRES_PASSWORD={secrets_map['BT_POSTGRES_PASSWORD']}\n"
        f"BT_REDIS_PASSWORD={secrets_map['BT_REDIS_PASSWORD']}\n"
        f"JWT_SECRET={secrets_map['JWT_SECRET']}\n"
        f"JWT_REFRESH_SECRET={secrets_map['JWT_REFRESH_SECRET']}\n"
        f"ENCRYPTION_KEY={secrets_map['ENCRYPTION_KEY']}\n"
        f"CRM_INTEGRATION_KEY={secrets_map['CRM_INTEGRATION_KEY']}\n"
        f"CRM_WEBHOOK_SECRET={secrets_map['CRM_WEBHOOK_SECRET']}\n"
        f"MT5_FEED_TOKEN={secrets_map['MT5_FEED_TOKEN']}\n"
        f"BRIDGE_TOKEN={secrets_map['BRIDGE_TOKEN']}\n"
        "\n"
        "URLs (plain HTTP):\n"
        f"  CRM:          http://{IP}:8000/\n"
        f"  CRM admin:    http://{IP}:8000/admin/\n"
        f"  BT API:       http://{IP}:4100/\n"
        f"  BT WebSocket: ws://{IP}:4101/\n"
        f"  BT Admin:     http://{IP}:4200/\n"
        f"  MT5 ingest:   http://{IP}:4300/\n"
        f"  BT Trader:    http://{IP}:4400/\n"
        "\n"
        "CRM Integration Base URL (internal): http://btrader-gateway:4100\n"
        f"CRM Webhook URL: http://{IP}:8000/api/btrader/webhook/\n"
        f"Windows MT5 FeedUrl: http://{IP}:4300\n"
        "X-Feed-Token header = MT5_FEED_TOKEN above\n"
    )
    CRED.write_text(cred_body, encoding="utf-8")
    CRED.chmod(0o600)

    # Ensure web dirs exist for Caddy mounts
    (ROOT / "web" / "admin").mkdir(parents=True, exist_ok=True)
    (ROOT / "web" / "trader").mkdir(parents=True, exist_ok=True)
    for name in ("admin", "trader"):
        idx = ROOT / "web" / name / "index.html"
        if not idx.exists():
            idx.write_text(f"<p>{name}</p>\n", encoding="utf-8")

    print("ENV_OK")
    print(f"Wrote {ENV}")
    print(f"Wrote {CRED}")


if __name__ == "__main__":
    main()
