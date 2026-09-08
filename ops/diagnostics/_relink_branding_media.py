import os
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
import django
django.setup()
from django.db import connection
from django.db.migrations.recorder import MigrationRecorder
from admin_panel.models import OrganizationProfileSettings

rec = MigrationRecorder.Migration
print("MIGRATION_0091", list(rec.objects.filter(app="admin_panel", name__contains="0091").values_list("name", flat=True)))
o = OrganizationProfileSettings.get_solo()
updates = []
candidates = {
    "app_icon": "organization/icons/WhatsApp_Image_2026-08-06_at_7.38.52_AM.jpeg",
    "login_logo": "organization/login/WhatsApp_Image_2026-08-06_at_7.41.40_AM.jpeg",
    "sidebar_logo": "organization/sidebar/WhatsApp_Image_2026-08-06_at_7.57.44_AM.jpeg",
}
for field, path in candidates.items():
    cur = getattr(o, field, None)
    name = getattr(cur, "name", None) if cur is not None else None
    print(f"BEFORE {field}={name!r}")
    if not name:
        full = f"/app/media/{path}"
        if os.path.isfile(full):
            setattr(o, field, path)
            updates.append(field)
            print(f"RELINKED {field} -> {path}")
        else:
            print(f"MISSING_FILE {full}")
    else:
        print(f"KEEP {field}")
if updates:
    o.save(update_fields=updates + ["updated_at"])
    print("SAVED", updates)
else:
    print("NO_RELINK_NEEDED")
with connection.cursor() as c:
    c.execute(
        "SELECT logo, app_icon, login_logo, sidebar_logo, company_name "
        "FROM admin_panel_organizationprofilesettings WHERE id=1"
    )
    print("ROW", c.fetchone())
print("HAS_ATTRS", hasattr(o, "app_icon"), hasattr(o, "login_logo"), hasattr(o, "sidebar_logo"))