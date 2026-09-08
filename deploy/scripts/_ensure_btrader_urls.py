#!/usr/bin/env python3
"""Ensure .env.prod.ip has fully-formed BTRADER_* URLs for compose."""
from pathlib import Path

p = Path("/opt/burjex/deploy/.env.prod.ip")
text = p.read_text()
vals = {}
for line in text.splitlines():
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    vals[k] = v

user = vals.get("BT_POSTGRES_USER", "btrader")
pw = vals["BT_POSTGRES_PASSWORD"]
db = vals.get("BT_POSTGRES_DB", "btrader")
rpw = vals["BT_REDIS_PASSWORD"]
need = {
    "BTRADER_DATABASE_URL": (
        f"postgresql://{user}:{pw}@btrader-postgres:5432/{db}"
        f"?schema=public&connection_limit=5"
    ),
    "BTRADER_REDIS_URL": f"redis://:{rpw}@btrader-redis:6379",
}

import re

changed = False
for k, v in need.items():
    if re.search(rf"^{k}=", text, flags=re.M):
        new = re.sub(rf"^{k}=.*$", f"{k}={v}", text, flags=re.M)
        if new != text:
            text = new
            changed = True
    else:
        text = (
            text.rstrip()
            + "\n\n# Durable B-Trader service URLs (compose must not expand empty BT_*)\n"
            + f"{k}={v}\n"
        )
        changed = True

if changed:
    p.write_text(text)
    print("updated")
else:
    print("unchanged")
for k in need:
    assert re.search(rf"^{k}=", p.read_text(), flags=re.M), k
print("ok")
