#Requires -Version 5.1
<#
  Create web\admin and web\trader under the repo root (sibling of deploy\).
  Safe to re-run. Does not overwrite existing index.html.
#>
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$admin = Join-Path $RepoRoot "web\admin"
$trader = Join-Path $RepoRoot "web\trader"

New-Item -ItemType Directory -Force -Path $admin, $trader | Out-Null

$adminIndex = Join-Path $admin "index.html"
$traderIndex = Join-Path $trader "index.html"
if (-not (Test-Path $adminIndex)) {
  Set-Content $adminIndex "<!doctype html><html><head><meta charset=utf-8><title>BTrader Admin</title></head><body><h1>BTrader Admin</h1><p>Upload Flutter web build here</p></body></html>"
}
if (-not (Test-Path $traderIndex)) {
  Set-Content $traderIndex "<!doctype html><html><head><meta charset=utf-8><title>BTrader</title></head><body><h1>BTrader Web</h1><p>Upload Flutter web build here</p></body></html>"
}

Write-Host "Ready:" -ForegroundColor Green
Write-Host "  $admin"
Write-Host "  $trader"
Write-Host ""
Write-Host "Set in deploy\.env.prod.ip (forward slashes):"
$fwdAdmin = ($admin -replace '\\', '/')
$fwdTrader = ($trader -replace '\\', '/')
Write-Host "  BURJEX_WEB_ADMIN=$fwdAdmin"
Write-Host "  BURJEX_WEB_TRADER=$fwdTrader"
