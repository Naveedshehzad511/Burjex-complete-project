
from api.services.signup_demo import _pick_demo_account_type, provision_signup_demo_account
from admin_panel.models import DemoAccountSettings, TradingAccount
from accounts.models import User, MT5Account
from user_portal.views import _display_open_account_type_name, _open_account_type_payload
from django.utils.crypto import get_random_string

cfg = DemoAccountSettings.get_solo()
t = _pick_demo_account_type(cfg)
print("PICK", getattr(t, "id", None), getattr(t, "account_name", None))
g = getattr(t, "crm_group", None) if t else None
print("GROUP", getattr(g, "platform", None), getattr(g, "platform_group_name", None) or getattr(g, "name", None))
print("STRIP", _display_open_account_type_name("Standard (BTrader)"))
if t:
    payload = _open_account_type_payload(t, demo_types_exist=True, is_demo_flow=True)
    print("TYPE_NAME", payload.get("name"))

email = f"autodemo_{get_random_string(6).lower()}@burjex.test"
user = User.objects.create_user(
    username=email.split("@")[0],
    email=email,
    first_name="Auto",
    last_name="Demo",
    password=get_random_string(12),
    role=User.Roles.CLIENT,
)
print("USER", user.pk, user.email)
creds = provision_signup_demo_account(user)
print("CREDS", creds)
mt5_n = MT5Account.objects.filter(user=user).count()
ta_n = TradingAccount.objects.filter(user=user).count()
print("COUNTS", mt5_n, ta_n)
print("PROOF_OK" if (creds and mt5_n == 1 and ta_n == 1) else "PROOF_FAIL")
