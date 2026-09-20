$ErrorActionPreference = 'Stop'

# Creates/starts the narrowly scoped host control process used by the Admin
# weekend restart action. It restarts only the five explicit application
# services; its source hard-codes the approved repo and Compose project.
$root = 'C:\Burjex-complete-project'
$taskName = 'BurjexServerRestartController'
$node = (Get-Command node.exe -ErrorAction Stop).Source
$controller = Join-Path $root 'btrader\ops\server-restart-controller.cjs'

if (!(Test-Path $controller)) {
  throw "Controller is missing: $controller"
}

$action = New-ScheduledTaskAction -Execute $node -Argument "`"$controller`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

# Do not expose the controller to public internet clients. Docker Desktop's
# internal ranges can reach it; every restart request also needs the secret
# token held in deploy\.env.github.
$ruleName = 'Burjex restart controller (Docker internal only)'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 4150 -RemoteAddress '172.16.0.0/12' | Out-Null
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 4150 -RemoteAddress '192.168.0.0/16' | Out-Null

Start-ScheduledTask -TaskName $taskName
Write-Output "Started $taskName"
