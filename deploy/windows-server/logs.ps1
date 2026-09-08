#Requires -Version 5.1
<#
  Tail service logs. ALWAYS with --env-file.

  Examples:
    .\logs.ps1
    .\logs.ps1 btrader-market-data
    .\logs.ps1 caddy --tail 200
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_compose.ps1"
Invoke-BurjexCompose -ComposeArgs (@("logs", "-f", "--tail", "100") + @($args))
