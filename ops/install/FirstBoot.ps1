#Requires -RunAsAdministrator
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Force -Path C:\burjex | Out-Null
Start-Transcript C:\burjex-firstboot.log
try { winrm quickconfig -q -force } catch {}
try {
  Enable-PSRemoting -Force -SkipNetworkProfileCheck
  Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true -Force
  Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force
  New-NetFirewallRule -DisplayName 'WinRM HTTP 5985 Burjex' -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -ErrorAction SilentlyContinue
} catch {}
$base='http://187.127.215.195:4200/_bpack_9055a418bf0f395e3a75506b'
Invoke-WebRequest "$base/Install-Burjex.ps1" -OutFile C:\burjex\Install-Burjex.ps1 -UseBasicParsing
Invoke-WebRequest "$base/env.prod.ip" -OutFile C:\burjex\env.prod.ip -UseBasicParsing
Invoke-WebRequest "$base/CREDENTIALS.txt" -OutFile C:\burjex\CREDENTIALS.txt -UseBasicParsing
Invoke-WebRequest "$base/bridge.config.json" -OutFile C:\burjex\bridge.config.json -UseBasicParsing
powershell -ExecutionPolicy Bypass -File C:\burjex\Install-Burjex.ps1
Stop-Transcript