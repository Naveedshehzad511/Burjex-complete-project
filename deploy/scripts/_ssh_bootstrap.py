"""One-shot helper: install the local deploy public key on the VPS using password auth.

Password is read from the BURJEX_VPS_PASSWORD environment variable so it never
lands in shell history or this file.
"""

import os
import pathlib
import sys

import paramiko

HOST = os.environ.get("BURJEX_VPS_HOST", "187.127.215.195")
USER = os.environ.get("BURJEX_VPS_USER", "root")
PASSWORD = os.environ.get("BURJEX_VPS_PASSWORD")

if not PASSWORD:
    sys.exit("BURJEX_VPS_PASSWORD not set")

pub_key = (pathlib.Path.home() / ".ssh" / "burjex_vps.pub").read_text().strip()

client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect(HOST, username=USER, password=PASSWORD, timeout=30, look_for_keys=False, allow_agent=False)

commands = [
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh",
    f"grep -qxF '{pub_key}' ~/.ssh/authorized_keys 2>/dev/null || echo '{pub_key}' >> ~/.ssh/authorized_keys",
    "chmod 600 ~/.ssh/authorized_keys",
    "echo KEY_INSTALLED; . /etc/os-release && echo OS=$PRETTY_NAME; echo CPU=$(nproc); "
    "echo RAM=$(free -m | awk '/Mem:/{print $2}')MB; echo DISK=$(df -h / | awk 'NR==2{print $4}'); "
    "echo DOCKER=$(docker --version 2>/dev/null || echo none)",
]

for cmd in commands:
    stdin, stdout, stderr = client.exec_command(cmd, timeout=60)
    out = stdout.read().decode().strip()
    err = stderr.read().decode().strip()
    if out:
        print(out)
    if err:
        print("ERR:", err, file=sys.stderr)

client.close()
