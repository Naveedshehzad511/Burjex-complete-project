$ErrorActionPreference = "Stop"
$Root = "D:\Burjex-Prime-Crm-main"
$Tgz = Join-Path $Root ("_deploy_{0}.tgz" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$Key = Join-Path $env:USERPROFILE ".ssh\burjex_vps"
$HostName = "187.127.215.195"
$SshBase = @("-i", $Key, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=30")

Write-Host "==> Creating slim stage + archive..."
$Stage = Join-Path $Root ("_deploy_upload_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Path $Stage | Out-Null
Write-Host ("  stage={0}" -f $Stage)
Write-Host ("  tgz={0}" -f $Tgz)

$xd = @(
  "node_modules", ".git", "build", ".dart_tool", "venv", ".venv",
  "__pycache__", ".gradle", "Pods", "dist", "archive", ".idea", ".vscode",
  "_deploy_upload", "media", "staticfiles", "static_root", "coverage",
  ".tools", "mockups", "ios", "android", "windows", "macos", "linux",
  "test", "tests", ".pytest_cache", "htmlcov", "bridges",
  "templates_backup", "storage", "forexten_mobile"
)
$xf = @("*.apk", "*.pyc", "db.sqlite3", "*.log", "_deploy.tgz", "*.aab", "*.ipa")

foreach ($dir in @("Burjex-Prime-Crm-main", "btrader", "deploy")) {
  $src = Join-Path $Root $dir
  $dst = Join-Path $Stage $dir
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  Write-Host "  robocopy $dir ..."
  & robocopy $src $dst /E /NFL /NDL /NJH /NJS /nc /ns /np /XD @xd /XF @xf | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $dir code=$LASTEXITCODE" }
}

$flutterApps = Join-Path $Stage "btrader\flutter"
if (Test-Path $flutterApps) {
  Write-Host "  trimming btrader/flutter apps..."
  Get-ChildItem $flutterApps -Directory -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -in @("apps", "archive")
  } | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
}

New-Item -ItemType Directory -Path (Join-Path $Stage "web\admin") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Stage "web\trader") -Force | Out-Null
@(
  "<!doctype html><html><head><meta charset=utf-8><title>BTrader Admin</title></head>"
  "<body><h1>BTrader Admin</h1><p>Upload Flutter web build to /opt/burjex/web/admin</p></body></html>"
) | Set-Content (Join-Path $Stage "web\admin\index.html")
@(
  "<!doctype html><html><head><meta charset=utf-8><title>BTrader</title></head>"
  "<body><h1>BTrader Web</h1><p>Upload Flutter web build to /opt/burjex/web/trader</p></body></html>"
) | Set-Content (Join-Path $Stage "web\trader\index.html")

Write-Host "==> tarring..."
Push-Location $Stage
try {
  & tar -czf $Tgz *
  if ($LASTEXITCODE -ne 0) { throw "tar failed" }
} finally {
  Pop-Location
}

$mb = [math]::Round((Get-Item $Tgz).Length / 1MB, 1)
Write-Host "==> Archive size: ${mb} MB"

Write-Host "==> Uploading archive + scripts..."
& scp @SshBase $Tgz "root@${HostName}:/tmp/burjex_deploy.tgz"
if ($LASTEXITCODE -ne 0) { throw "scp archive failed" }
& scp @SshBase (Join-Path $Root "deploy\_remote_setup.py") "root@${HostName}:/tmp/_remote_setup.py"
if ($LASTEXITCODE -ne 0) { throw "scp setup py failed" }
& scp @SshBase (Join-Path $Root "deploy\_remote_up.sh") "root@${HostName}:/tmp/_remote_up.sh"
if ($LASTEXITCODE -ne 0) { throw "scp up sh failed" }

Write-Host "==> Running remote extract + docker compose (long build)..."
& ssh @SshBase "root@$HostName" "bash /tmp/_remote_up.sh"
if ($LASTEXITCODE -ne 0) { throw "remote setup failed code=$LASTEXITCODE" }

Write-Host "==> DONE - live URLs:"
Write-Host ("  CRM:          http://{0}:8000/" -f $HostName)
Write-Host ("  CRM admin:    http://{0}:8000/admin/" -f $HostName)
Write-Host ("  BT API:       http://{0}:4100/" -f $HostName)
Write-Host ("  BT WebSocket: ws://{0}:4101/" -f $HostName)
Write-Host ("  BT Admin:     http://{0}:4200/" -f $HostName)
Write-Host ("  MT5 ingest:   http://{0}:4300/" -f $HostName)
Write-Host ("  BT Trader:    http://{0}:4400/" -f $HostName)
