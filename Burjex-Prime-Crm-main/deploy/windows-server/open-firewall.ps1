#Requires -Version 5.1
<#
  Open Windows Firewall inbound rules for the Burjex IP-mode ports.
  Run elevated (Administrator).

  Ports: 8000 CRM | 4100 REST | 4101 WS | 4200 admin | 4300 MT5 ingest | 4400 trader
  Also ensure your cloud/provider security group opens the same ports.
#>
$ErrorActionPreference = "Stop"

$rules = @(
  @{ Name = "Burjex CRM 8000";          Port = 8000 },
  @{ Name = "Burjex BTrader REST 4100"; Port = 4100 },
  @{ Name = "Burjex BTrader WS 4101";   Port = 4101 },
  @{ Name = "Burjex BTrader Admin 4200"; Port = 4200 },
  @{ Name = "Burjex MT5 Ingest 4300";   Port = 4300 },
  @{ Name = "Burjex BTrader Web 4400";  Port = 4400 }
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
  IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  throw "Run this script as Administrator (elevated PowerShell)."
}

foreach ($r in $rules) {
  $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "Exists: $($r.Name)" -ForegroundColor Yellow
    continue
  }
  New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $r.Port -Profile Any | Out-Null
  Write-Host "Opened TCP $($r.Port) — $($r.Name)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. If this is Azure/AWS/Oracle/etc., open the same ports in the cloud NSG/security group too." -ForegroundColor Cyan
Write-Host "Optional harden: restrict 4300 to known IPs only (same-machine bridge can stay on 127.0.0.1 and needs no public 4300)." -ForegroundColor Cyan
