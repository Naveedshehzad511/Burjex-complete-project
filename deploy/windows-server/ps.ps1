#Requires -Version 5.1
<# docker compose ps — ALWAYS with --env-file. #>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_compose.ps1"
Invoke-BurjexCompose -ComposeArgs (@("ps") + @($args))
