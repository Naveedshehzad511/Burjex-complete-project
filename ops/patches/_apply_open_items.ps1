$ErrorActionPreference='Continue'
$d='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$zip='C:\burjex\_finish_open_items.zip'
$stage='C:\burjex\_finish_stage'
if (-not (Test-Path $zip)) { throw "missing zip $zip" }
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
Write-Output '=== expanded ==='
Get-ChildItem -Recurse $stage -File | ForEach-Object { ($_.FullName.Substring($stage.Length+1)) + ' ' + $_.Length }

$pairs = @(
  @('Burjex-Prime-Crm-main\accounts\views.py', 'C:\burjex\Burjex-Prime-Crm-main\accounts\views.py'),
  @('Burjex-Prime-Crm-main\admin_panel\models.py', 'C:\burjex\Burjex-Prime-Crm-main\admin_panel\models.py'),
  @('Burjex-Prime-Crm-main\admin_panel\views.py', 'C:\burjex\Burjex-Prime-Crm-main\admin_panel\views.py'),
  @('Burjex-Prime-Crm-main\admin_panel\migrations\0091_organization_branding_asset_slots.py', 'C:\burjex\Burjex-Prime-Crm-main\admin_panel\migrations\0091_organization_branding_asset_slots.py'),
  @('Burjex-Prime-Crm-main\templates\admin_panel\branding_settings.html', 'C:\burjex\Burjex-Prime-Crm-main\templates\admin_panel\branding_settings.html'),
  @('Burjex-Prime-Crm-main\api\views\branding.py', 'C:\burjex\Burjex-Prime-Crm-main\api\views\branding.py'),
  @('Burjex-Prime-Crm-main\api\services\treasury_service.py', 'C:\burjex\Burjex-Prime-Crm-main\api\services\treasury_service.py'),
  @('Burjex-Prime-Crm-main\transactions\internal_transfer_execution.py', 'C:\burjex\Burjex-Prime-Crm-main\transactions\internal_transfer_execution.py')
)
foreach ($p in $pairs) {
  $src = Join-Path $stage $p[0]
  $dst = $p[1]
  if (-not (Test-Path $src)) { throw "missing staged $src" }
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  Copy-Item -Force $src $dst
  Write-Output ("HOST_OK " + $p[0] + " size=" + (Get-Item $dst).Length)
}

$dockerPairs = @(
  @('C:\burjex\Burjex-Prime-Crm-main\accounts\views.py', '/app/accounts/views.py'),
  @('C:\burjex\Burjex-Prime-Crm-main\admin_panel\models.py', '/app/admin_panel/models.py'),
  @('C:\burjex\Burjex-Prime-Crm-main\admin_panel\views.py', '/app/admin_panel/views.py'),
  @('C:\burjex\Burjex-Prime-Crm-main\admin_panel\migrations\0091_organization_branding_asset_slots.py', '/app/admin_panel/migrations/0091_organization_branding_asset_slots.py'),
  @('C:\burjex\Burjex-Prime-Crm-main\templates\admin_panel\branding_settings.html', '/app/templates/admin_panel/branding_settings.html'),
  @('C:\burjex\Burjex-Prime-Crm-main\api\views\branding.py', '/app/api/views/branding.py'),
  @('C:\burjex\Burjex-Prime-Crm-main\api\services\treasury_service.py', '/app/api/services/treasury_service.py'),
  @('C:\burjex\Burjex-Prime-Crm-main\transactions\internal_transfer_execution.py', '/app/transactions/internal_transfer_execution.py')
)
foreach ($c in @('crm_web','crm_worker','crm_beat')) {
  $cid = (& $d ps -q -f "name=$c" | Select-Object -First 1)
  if (-not $cid) { throw "missing container $c" }
  foreach ($p in $dockerPairs) {
    & $d cp $p[0] ($c + ':' + $p[1]) | Out-Null
  }
  Write-Output ("COPIED $c")
}

Write-Output '=== migrate branding ==='
& $d exec crm_web python manage.py migrate admin_panel 0091 --noinput 2>&1 | ForEach-Object { "$_" }
Write-Output ("migrate_exit=" + $LASTEXITCODE)

Write-Output '=== ensure crm_worker ==='
Set-Location C:\burjex\deploy\windows-server
powershell -NoProfile -ExecutionPolicy Bypass -File .\up.ps1 up -d crm-worker 2>&1 | Select-Object -Last 20 | ForEach-Object { "$_" }
& $d restart crm_web crm_worker crm_beat 2>&1 | ForEach-Object { "$_" }
Start-Sleep -Seconds 22

Write-Output '=== markers ==='
$m1 = & $d exec crm_web sh -c "grep -c startswith.skipped_ /app/accounts/views.py || true"
$m2 = & $d exec crm_web sh -c "grep -c app_icon_url /app/api/views/branding.py || true"
$m3 = & $d exec crm_web sh -c "grep -c branding_slots /app/admin_panel/views.py || true"
$m4 = & $d exec crm_web sh -c "grep -c pending_wallet_out /app/transactions/internal_transfer_execution.py || true"
$m5 = & $d exec crm_web sh -c "grep -c Recommended.1024 /app/admin_panel/views.py || true"
Write-Output ("MARKERS skipped=$m1 app_icon=$m2 slots=$m3 pending=$m4 hint1024=$m5")
$ok = ($m1 -match '[1-9]') -and ($m2 -match '[1-9]') -and ($m3 -match '[1-9]') -and ($m4 -match '[1-9]')
if (-not $ok) { throw 'markers missing after deploy' }

& $d ps --filter name=crm --format '{{.Names}}|{{.Status}}'
try {
  $b = Invoke-WebRequest -Uri 'http://127.0.0.1/api/v1/branding/' -UseBasicParsing -TimeoutSec 20
  $snip = $b.Content
  if ($snip.Length -gt 400) { $snip = $snip.Substring(0,400) }
  Write-Output ("BRANDING_API " + $b.StatusCode + " " + $snip)
} catch {
  Write-Output ("BRANDING_API_ERR " + $_.Exception.Message)
}

Write-Output '=== resend unverified ==='
$pycode = @"
from django.utils import timezone
from datetime import timedelta
from accounts.models import User
from accounts.views import _send_verification_email
from django.test import RequestFactory
import uuid
since = timezone.now() - timedelta(hours=96)
qs = list(User.objects.filter(role=User.Roles.CLIENT, date_joined__gte=since, email_verified=False).order_by('-date_joined')[:10])
print('UNVERIFIED_COUNT', len(qs))
rf = RequestFactory()
req = rf.get('/')
req.META['HTTP_HOST'] = '5.226.139.8'
req.META['SERVER_NAME'] = '5.226.139.8'
req.META['wsgi.url_scheme'] = 'http'
for u in qs:
    if not (u.email_token or '').strip():
        u.email_token = uuid.uuid4().hex
        u.email_token_created_at = timezone.now()
        u.save(update_fields=['email_token', 'email_token_created_at'])
        print('TOKEN_ISSUED', u.pk, u.email)
    try:
        _send_verification_email(u, req)
        print('RESEND_OK', u.pk, u.email)
    except Exception as ex:
        print('RESEND_FAIL', u.pk, u.email, type(ex).__name__, ex)
"@
Set-Content -Path C:\burjex\_resend_verify_inner.py -Value $pycode -Encoding utf8
Get-Content C:\burjex\_resend_verify_inner.py -Raw | & $d exec -i crm_web python manage.py shell 2>&1
Write-Output 'APPLY_DONE'
