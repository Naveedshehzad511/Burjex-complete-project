#Requires -Version 5.1
<#
  Recreate containers (force). ALWAYS with --env-file.

  DO NOT run:
    docker compose up -d --force-recreate
  without --env-file — that caused market-data crash-loop / :4300 timeouts.

  Examples:
    .\recreate.ps1
    .\recreate.ps1 btrader-market-data
#>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_compose.ps1"
Invoke-BurjexCompose -ComposeArgs (@("up", "-d", "--force-recreate", "--no-build") + @($args))
