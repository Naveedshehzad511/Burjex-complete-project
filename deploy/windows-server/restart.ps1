#Requires -Version 5.1
<#
  Restart one or more services. ALWAYS with --env-file.

  CRITICAL: Never use `docker compose up -d --force-recreate` without --env-file.
  That is what emptied BT_* / DATABASE_URL / REDIS_URL and crashed market-data.

  Examples:
    .\restart.ps1 caddy
    .\restart.ps1 btrader-market-data btrader-gateway
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_compose.ps1"
if (-not $args -or $args.Count -eq 0) {
  throw "Usage: .\restart.ps1 <service> [service2 ...]"
}
Invoke-BurjexCompose -ComposeArgs (@("restart") + @($args))
