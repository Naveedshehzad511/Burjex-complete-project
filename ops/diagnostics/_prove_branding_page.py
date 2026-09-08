
import os, sys
sys.path.insert(0, "/app")
os.chdir("/app")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
import django
django.setup()
from django.test import RequestFactory
from django.contrib.auth import get_user_model
from admin_panel.views import branding_logo
from django.urls import reverse
from admin_panel.models import OrganizationProfileSettings

User = get_user_model()
u = User.objects.filter(is_superuser=True).first() or User.objects.filter(role="ADMIN").first()
print("USER", getattr(u, "username", None), getattr(u, "role", None))
rf = RequestFactory()
req = rf.get("/admin/system-management/branding/")
req.user = u
resp = branding_logo(req)
print("STATUS", resp.status_code)
html = resp.content.decode("utf-8", "replace")
for needle in [
    "App icon", "Login logo", "Sidebar logo", "Company logo",
    'name="app_icon"', 'name="login_logo"', 'name="sidebar_logo"', 'name="company_logo"',
    "1024", "600x200", "200x200",
    "WhatsApp_Image_2026-08-06_at_7.38.52_AM.jpeg",
    "WhatsApp_Image_2026-08-06_at_7.41.40_AM.jpeg",
    "WhatsApp_Image_2026-08-06_at_7.57.44_AM.jpeg",
]:
    print(f"HAS[{needle}]={needle in html}")
print("URL_REVERSE", reverse("admin-branding-logo"))
print("URL_SM", reverse("system-management-branding"))
o = OrganizationProfileSettings.get_solo()
print("DB_app_icon", getattr(getattr(o,"app_icon",None),"name",None))
print("DB_login_logo", getattr(getattr(o,"login_logo",None),"name",None))
print("DB_sidebar_logo", getattr(getattr(o,"sidebar_logo",None),"name",None))
print("DB_logo", getattr(getattr(o,"logo",None),"name",None))
