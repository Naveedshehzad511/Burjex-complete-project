#Requires -Version 5.1
<# Stop the Burjex stack. ALWAYS passes --env-file. #>
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_compose.ps1"
Invoke-BurjexCompose -ComposeArgs (@("down") + @($args))
