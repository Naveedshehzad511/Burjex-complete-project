#Requires -Version 5.1
<#
.SYNOPSIS
  Shared helper: run docker compose for Burjex ALWAYS with --env-file.

.DESCRIPTION
  NEVER invoke `docker compose up/recreate/restart` without --env-file.
  Missing env-file empties BT_* / DATABASE_URL / REDIS_URL -> market-data
  crash-loop -> ingest :4300 timeouts -> price stutter.

  Runtime secrets file (same name as Linux IP deploy):
    <repo>\deploy\.env.prod.ip

  Copy from:
    <repo>\deploy\windows-server\.env.windows-server.example
#>

$ErrorActionPreference = "Stop"

function Get-BurjexPaths {
  $WinServerDir = $PSScriptRoot
  $DeployDir = Split-Path -Parent $WinServerDir
  $RepoRoot = Split-Path -Parent $DeployDir
  $EnvFile = Join-Path $DeployDir ".env.prod.ip"
  $ComposeFile = Join-Path $DeployDir "docker-compose.ip.yml"
  [pscustomobject]@{
    WinServerDir = $WinServerDir
    DeployDir    = $DeployDir
    RepoRoot     = $RepoRoot
    EnvFile      = $EnvFile
    ComposeFile  = $ComposeFile
  }
}

function Assert-BurjexEnvFile {
  param([Parameter(Mandatory)]$Paths)
  if (-not (Test-Path -LiteralPath $Paths.EnvFile)) {
    $example = Join-Path $Paths.WinServerDir ".env.windows-server.example"
    throw @"
MISSING env file: $($Paths.EnvFile)

Copy the template and fill secrets first:
  Copy-Item '$example' '$($Paths.EnvFile)'
  # then edit $($Paths.EnvFile) - replace YOUR_SERVER_IP and every CHANGE_ME

CRITICAL: Never run docker compose without --env-file.
Without it, BT_*/DATABASE_URL/REDIS_URL are empty -> market-data crash-loop -> :4300 ingest timeouts.
"@
  }
  if (-not (Test-Path -LiteralPath $Paths.ComposeFile)) {
    throw "Missing compose file: $($Paths.ComposeFile)"
  }
}

function Invoke-BurjexCompose {
  <#
  .SYNOPSIS
    docker compose -f deploy/docker-compose.ip.yml --env-file deploy/.env.prod.ip <args>
  .EXAMPLE
    Invoke-BurjexCompose -ComposeArgs @('up','-d','--build')
    Invoke-BurjexCompose -ComposeArgs @('logs','-f','btrader-market-data')
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$ComposeArgs
  )
  $p = Get-BurjexPaths
  Assert-BurjexEnvFile -Paths $p

  if (-not $ComposeArgs -or $ComposeArgs.Count -eq 0) {
    throw "Invoke-BurjexCompose requires -ComposeArgs (e.g. up -d --build). Env-file is always injected."
  }

  $joined = ($ComposeArgs -join " ")
  if ($joined -match '--env-file(\s+(""|''''|\s)|$)') {
    throw "Do not pass an empty --env-file. This helper always uses: $($p.EnvFile)"
  }

  # Docker Desktop on this box carries a `credsStore` entry naming a helper that
  # is not installed, so every build that pulls a base image dies with:
  #   error getting credentials - exec: "docker-credential-burjexnull":
  #   executable file not found in %PATH%
  # Every image this stack uses is public, so no credentials are needed at all.
  # Point DOCKER_CONFIG at a config with no credsStore. This is process-scoped:
  # the interactive `docker login` state under the user profile is untouched.
  $cfgDir = Join-Path $p.RepoRoot "_dockercfg"
  $cfgFile = Join-Path $cfgDir "config.json"
  if (-not (Test-Path -LiteralPath $cfgFile)) {
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    '{}' | Set-Content -LiteralPath $cfgFile -Encoding ascii
  }
  $env:DOCKER_CONFIG = $cfgDir

  Push-Location $p.RepoRoot
  try {
    Write-Host "==> docker compose -f `"$($p.ComposeFile)`" --env-file `"$($p.EnvFile)`" $($ComposeArgs -join ' ')" -ForegroundColor Cyan
    & docker compose -f $p.ComposeFile --env-file $p.EnvFile @ComposeArgs
    if ($LASTEXITCODE -ne 0) {
      throw "docker compose failed with exit code $LASTEXITCODE"
    }
  }
  finally {
    Pop-Location
  }
}

# If executed directly (not dot-sourced), forward remaining args.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.') {
  if ($args.Count -eq 0) {
    Write-Host "Usage:"
    Write-Host "  . .\deploy\windows-server\_compose.ps1"
    Write-Host "  Invoke-BurjexCompose -ComposeArgs @('ps')"
    Write-Host "  .\deploy\windows-server\up.ps1"
    exit 1
  }
  Invoke-BurjexCompose -ComposeArgs @($args)
}
