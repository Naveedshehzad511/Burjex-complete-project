#Requires -Version 5.1
<#
  Build + start the full Burjex stack (CRM + BTrader + redis/postgres + caddy).

  ALWAYS uses: --env-file deploy\.env.prod.ip
  Never run raw `docker compose up` without that flag.
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_compose.ps1"

$extra = @($args)
if ($extra.Count -eq 0) {
  $extra = @("up", "-d", "--build")
}
elseif ($extra[0] -notin @("up", "create", "run")) {
  # Allow: .\up.ps1 --force-recreate
  $extra = @("up", "-d", "--build") + $extra
}

Invoke-BurjexCompose -ComposeArgs $extra
Write-Host ""
Write-Host "Stack starting. Check: .\ps.ps1   Logs: .\logs.ps1 btrader-market-data" -ForegroundColor Green
