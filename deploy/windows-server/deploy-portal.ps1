#Requires -Version 5.1
<#
  Publish the Burjex Prime portal (the forexten web build).

      .\deploy-portal.ps1            copy staged bundle into the live directory
      .\deploy-portal.ps1 -DryRun    show what would change, copy nothing

  Flow: build on a workstation (forexten_mobile/build-web.sh ip), copy the
  bundle to C:\burjex\web\_incoming\portal, then run this.

  Why mirroring rather than a fresh copy: the bundle is ~42 MB but ~37 MB of it
  is canvaskit/, which is byte-identical between builds. Only main.dart.js
  (~3.5 MB) and a few small files actually change, so /MIR moves ~4 MB per
  iteration instead of the whole thing.

  Why it never deletes the live directory: Docker bind-mounts an inode, not a
  path. Removing and recreating C:\burjex\web\portal leaves Caddy holding a
  handle to the old one and every request 404s until the container is recreated.
  /MIR updates in place, so the mount stays valid and no restart is needed.
#>
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

$Staging = 'C:\burjex\web\_incoming\portal'
$Live    = 'C:\burjex\web\portal'

if (-not (Test-Path $Staging)) {
  throw "staging directory not found: $Staging  (copy build/web there first)"
}
if (-not (Test-Path (Join-Path $Staging 'index.html'))) {
  throw "no index.html in $Staging - that is not a Flutter web build"
}

# Guard against publishing a bundle built for the wrong environment. A localhost
# build silently fails in the browser with only a CORS/connection error, which
# is a slow and confusing thing to debug on a live box.
$mainJs = Join-Path $Staging 'main.dart.js'
if (Test-Path $mainJs) {
  $head = Get-Content $mainJs -TotalCount 400 -ErrorAction SilentlyContinue
  if ($head -match 'localhost:(4100|4101|8000)') {
    throw "this bundle points at localhost - rebuild with: ./build-web.sh ip"
  }
}

New-Item -ItemType Directory -Force -Path $Live | Out-Null

$flags = @('/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:2')
if ($DryRun) { $flags += '/L' }

Write-Host "==> $(if ($DryRun) {'DRY RUN: '} else {''})mirroring $Staging -> $Live"
& robocopy $Staging $Live @flags | Out-Null
$rc = $LASTEXITCODE

# Robocopy exit codes are a bitmask: <8 is success (0 = no change, 1 = copied,
# 2 = extras removed, 3 = both). 8 and above are genuine failures.
if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }

if ($DryRun) {
  Write-Host "Dry run complete (robocopy rc=$rc). Nothing was changed."
  exit 0
}

switch ($rc) {
  0 { Write-Host "No changes - the live bundle already matches staging." }
  default { Write-Host "Published (robocopy rc=$rc)." }
}

Write-Host ""
Write-Host "  http://5.226.139.8:4500/"
Write-Host ""
Write-Host "  No container restart needed: /MIR updates files in place, so"
Write-Host "  Caddy's bind mount stays valid."
Write-Host "  Hard-refresh the browser (Ctrl+F5) - index.html is no-cache but"
Write-Host "  a previously loaded main.dart.js may still be in memory."
