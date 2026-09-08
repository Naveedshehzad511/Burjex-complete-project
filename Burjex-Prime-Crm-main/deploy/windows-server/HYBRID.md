# Hybrid mode — Docker Desktop blocked (no nested virtualization)

**Verdict (2026-08-04, host `5.226.139.8` / `Forexten`):** Docker Desktop **cannot** run Linux containers on this Windows Server until the provider exposes CPU virtualization (VT-x / nested Hyper-V) to the guest.

## Diagnosis (facts)

| Check | Result |
|---|---|
| OS | Windows Server 2025 Standard (build 26100) |
| Hardware SMBIOS | Supermicro SYS-5039MS-H12TRF / X11SSE-F (often passthrough on hosted VMs) |
| Hyper-V guest integration (`vmicheartbeat` etc.) | Present → this is a **VM**, not bare-metal root |
| `VirtualizationFirmwareEnabled` | **False** |
| SLAT / VMMonitorModeExtensions | **False** / **False** |
| `hypervisorlaunchtype` | Already `Auto` |
| Features | `Microsoft-Hyper-V` Enabled, `VirtualMachinePlatform` Enabled, WSL Enabled; `HypervisorPlatform`/`Containers` were Disabled |
| Docker Desktop | Installed; `com.docker.service` Stopped — UI: “Virtualization support not detected” |
| Sign-in | Irrelevant — does not enable VT-x |

**Conclusion:** Nested virtualization is **not** available. Enabling more Windows features / rebooting will not fix Docker Desktop. Stop fighting Docker on this box until the provider enables nested virt.

## Working architecture (keep old VPS)

```text
Windows Server 5.226.139.8          Linux VPS 187.127.215.195 (KEEP RUNNING)
┌─────────────────────────┐         ┌──────────────────────────────────────┐
│ MT5 Terminal / Manager  │         │ Full Docker stack (CRM + BTrader)    │
│ mt5_bridge.py (NSSM)    │──HTTP──▶│ ingest :4300  gateway :4100          │
│ FeedUrl → Linux :4300   │         │ live ticks already healthy           │
└─────────────────────────┘         └──────────────────────────────────────┘
```

- **Do not** shut down `187.127.215.195`.
- Bridge on Windows must use the **live** Linux tokens (`MT5_FEED_TOKEN` / `BRIDGE_TOKEN` from `/opt/burjex/deploy/.env.prod.ip`), not the unused Windows all-in-one staging tokens.
- Example bridge URLs:
  - `FeedUrl`: `http://187.127.215.195:4300`
  - `BridgeApiUrl` / `BtApiUrl`: `http://187.127.215.195:4100/v1`
- On Linux, `FEED_ALLOWED_IPS` should allow `5.226.139.8` (currently open `0.0.0.0/0` — OK for bring-up; tighten later).

## Files on Windows

| Path | Purpose |
|---|---|
| `C:\burjex\bridge.config.hybrid.json` | Hybrid config (FeedUrl → old VPS) |
| `C:\burjex\bridge.config.json` | Updated to hybrid once cutover is intended |
| `C:\burjex\PROVIDER-NESTED-VIRT-TICKET.txt` | Copy/paste ticket for hoster |
| `C:\burjex-MT5-NEXT.txt` | Human steps: install MT5, then start bridge |

## Provider ticket (English)

See `PROVIDER-NESTED-VIRT-TICKET.txt`. Short form:

> Please enable nested virtualization / VT-x / “Expose hardware virtualization extensions” for Windows VPS **5.226.139.8** (Windows Server 2025). Docker Desktop reports “Virtualization support not detected”; WMI shows `VirtualizationFirmwareEnabled=False` and SLAT unavailable. We need Hyper-V / WSL2 nested virt for Linux containers.

## After provider enables nested virt

1. Reboot the Windows VPS.
2. Confirm WMI: `VirtualizationFirmwareEnabled` / SLAT / VMMonitor = True (or Hyper-V requirements show enabled).
3. Start Docker Desktop → `docker version` engine running.
4. Then (optional) move full stack from Linux to Windows all-in-one; until then hybrid is fine.

## اردو (مختصر)

- **Docker کیوں فیل:** اس Windows VPS پر nested virtualization / VT-x نہیں ہے — Docker Desktop Linux containers نہیں چلا سکتا۔ Sign-in سے یہ ٹھیک نہیں ہوتا۔
- **اب کیا کریں:** پرانا Linux VPS (`187.127.215.195`) چلتا رکھیں۔ Windows پر صرف MT5 + bridge لگائیں، `FeedUrl=http://187.127.215.195:4300`۔
- **Provider سے پوچھیں:** اس VPS پر nested virtualization آن کریں۔ جب تک وہ نہ کریں، Windows پر پورا Docker stack ممکن نہیں۔
