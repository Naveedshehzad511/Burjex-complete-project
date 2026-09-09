#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$Root = 'C:\Burjex-complete-project'
$Log = 'C:\Windows\Temp\bxnet-up.log'
$Status = 'C:\Windows\Temp\bxnet-up.status'
Set-Content -LiteralPath $Status -Value 'RUNNING' -Encoding ascii
function Log($m) {
  $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
  Add-Content -LiteralPath $Log -Value $line
  Write-Output $line
}
try {
  Set-Location $Root
  Log 'prune unused build cache (live containers stay up)'
  docker builder prune -f | Out-Null
  Log 'compose up --build burjex_net'
  $env:COMPOSE_PARALLEL_LIMIT = '1'
  docker compose -p burjex_net -f deploy/docker-compose.github.yml --env-file deploy/.env.github up -d --build
  if ($LASTEXITCODE -ne 0) { throw "compose exit $LASTEXITCODE" }
  Log 'compose ps'
  docker compose -p burjex_net -f deploy/docker-compose.github.yml --env-file deploy/.env.github ps
  Set-Content -LiteralPath $Status -Value 'DONE' -Encoding ascii
  Log 'DONE'
} catch {
  Set-Content -LiteralPath $Status -Value ('FAIL ' + $_.Exception.Message) -Encoding ascii
  Log ('FAIL ' + $_.Exception.Message)
  exit 1
}
