import os, django
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
django.setup()
from admin_panel.models import BankField, CryptoNetwork
print("BANK FIELDS:")
for f in BankField.objects.all().order_by("id"):
    print(f"  key={f.field_key!r} enabled={f.is_enabled} required={f.is_required} label={f.label!r}")
print("CRYPTO NETWORKS:")
for n in CryptoNetwork.objects.all().order_by("id"):
    print(f"  code={getattr(n,'code',None)!r} label={getattr(n,'label',None)!r} enabled={getattr(n,'is_enabled',None)}")
