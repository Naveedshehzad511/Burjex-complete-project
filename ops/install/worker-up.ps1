$ErrorActionPreference='Continue'
$log='C:\burjex-task.log'
function L($m){ $line="[{0}] {1}" -f (Get-Date -Format o), $m; Add-Content $log $line }
L 'worker start'
$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')
$docker='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$dd='C:\Program Files\Docker\Docker\Docker Desktop.exe'
try { Start-Service com.docker.service -ErrorAction SilentlyContinue } catch {}
if(Test-Path $dd){ Start-Process $dd; L 'started Docker Desktop' }
# wait engine
$ok=$false
for($i=1; $i -le 60; $i++){
  Start-Sleep 10
  & wsl -d docker-desktop -- echo ok 2>$null | Out-Null
  $ver = & $docker version --format '{{.Server.Version}}' 2>$null
  if($LASTEXITCODE -eq 0 -and $ver){ L ("DOCKER_OK " + $ver); $ok=$true; break }
  L ("wait $i")
}
if(-not $ok){ L 'DOCKER_FAIL'; exit 2 }
# firewall clean
$fw='C:\burjex\deploy\windows-server\open-firewall.ps1'
if(Test-Path $fw){ try { & $fw } catch { L $_.Exception.Message } }
# env
if(Test-Path 'C:\burjex\env.prod.ip'){ Copy-Item 'C:\burjex\env.prod.ip' 'C:\burjex\deploy\.env.prod.ip' -Force }
$cfg='C:\burjex\btrader\bridges\mt5-manager-python\config.json'
if(Test-Path $cfg){
  try{ $j=Get-Content $cfg -Raw|ConvertFrom-Json; $j.FeedUrl='http://127.0.0.1:4300'; ($j|ConvertTo-Json -Depth 12)|Set-Content $cfg -Encoding utf8 }catch{}
}
L 'running up.ps1'
Set-Location 'C:\burjex\deploy\windows-server'
& .\up.ps1 *>&1 | ForEach-Object { L ("UP: " + $_) }
L ('UP_EXIT=' + $LASTEXITCODE)
# health wait
for($i=1; $i -le 90; $i++){
  $a=$false;$b=$false
  try{ $r=Invoke-WebRequest http://127.0.0.1:4300/health -UseBasicParsing -TimeoutSec 8; if($r.StatusCode -eq 200){$a=$true} }catch{}
  try{ $r=Invoke-WebRequest http://127.0.0.1:8000/health/ready/ -UseBasicParsing -TimeoutSec 8; if($r.StatusCode -eq 200){$b=$true} }catch{}
  L ("HEALTH $i 4300=$a 8000=$b")
  if($a -and $b){ L 'ALL_HEALTHY'; break }
  Start-Sleep 20
}
& $docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1 | ForEach-Object { L ("PS: " + $_) }
# bridge
$mt5=@('C:\Program Files\MetaTrader 5\terminal64.exe','C:\Program Files (x86)\MetaTrader 5\terminal64.exe')|?{Test-Path $_}|Select -First 1
$setup='C:\burjex\deploy\windows-server\setup-bridge-service.ps1'
if($mt5 -and (Test-Path $setup)){ L ("MT5=" + $mt5); & $setup -Start *>&1 | %{ L ("BR: $_") } }
else { L 'MT5_NOT_FOUND'; if(Test-Path $setup){ try{ & $setup *>&1|%{ L "BR: $_" } }catch{} }; 'Install MT5 + login once then setup-bridge-service.ps1 -Start'|Set-Content C:\burjex-MT5-NEXT.txt }
$pf='C:\burjex\deploy\windows-server\preflight-feed.ps1'
if(Test-Path $pf){ L 'PREFLIGHT'; try{ & $pf *>&1|%{ L "PF: $_" } }catch{ L $_.Exception.Message } }
L 'worker done'
