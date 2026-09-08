import os
os.environ.setdefault('DJANGO_SETTINGS_MODULE','config.settings')
import django
django.setup()
from django.db import connection
from django.db.migrations.recorder import MigrationRecorder
rec=MigrationRecorder.Migration
print('MIGRATION_0091=', list(rec.objects.filter(app='admin_panel', name__contains='0091').values_list('name', flat=True)))
print('LATEST_MIGS=', list(rec.objects.filter(app='admin_panel').order_by('-id').values_list('name', flat=True)[:10]))
with connection.cursor() as c:
    c.execute("SELECT column_name FROM information_schema.columns WHERE table_name=%s ORDER BY 1", ['admin_panel_organizationprofilesettings'])
    cols=[r[0] for r in c.fetchall()]
print('COLS_FILTER=', [x for x in cols if x in ('logo','app_icon','login_logo','sidebar_logo','company_name')])
from admin_panel.models import OrganizationProfileSettings
o=OrganizationProfileSettings.get_solo()
def n(f):
    try:
        return (getattr(f,'name',None) or '') if f is not None else ''
    except Exception as e:
        return 'ERR:'+str(e)
print('DB_logo=', n(getattr(o,'logo',None)))
print('DB_app_icon=', n(getattr(o,'app_icon',None)) if hasattr(o,'app_icon') else 'NO_ATTR')
print('DB_login_logo=', n(getattr(o,'login_logo',None)) if hasattr(o,'login_logo') else 'NO_ATTR')
print('DB_sidebar_logo=', n(getattr(o,'sidebar_logo',None)) if hasattr(o,'sidebar_logo') else 'NO_ATTR')
print('COMPANY=', o.company_name)
