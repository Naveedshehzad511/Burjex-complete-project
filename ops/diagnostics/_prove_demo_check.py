
from accounts.models import User, MT5Account
from admin_panel.models import TradingAccount, DemoAccountSettings
from api.services.signup_demo import provision_signup_demo_account, _pick_demo_account_type
from user_portal.views import _display_open_account_type_name
from django.utils.crypto import get_random_string

print("STRIP", _display_open_account_type_name("Standard (BTrader)"))
cfg = DemoAccountSettings.get_solo()
t = _pick_demo_account_type(cfg)
print("PICK", getattr(t, "id", None), getattr(t, "account_name", None), getattr(t, "demo_enabled", None), getattr(t, "account_category", None))
g = getattr(t, "crm_group", None) if t else None
print("GROUP", getattr(g, "platform", None), getattr(g, "platform_group_name", None) or getattr(g, "name", None))

u = User.objects.filter(pk=10).first()
if u:
    print("USER10", u.email)
    print("MT5", list(MT5Account.objects.filter(user=u).values_list("login_id", "account_type", "balance")))
    print("TA", list(TradingAccount.objects.filter(user=u).values_list("account_number", "account_type", "balance")))
    if not MT5Account.objects.filter(user=u).exists():
        creds = provision_signup_demo_account(u)
        print("RETRY_CREDS", creds)
        print("MT5_AFTER", list(MT5Account.objects.filter(user=u).values_list("login_id", "account_type", "balance")))
else:
    print("USER10 missing")

email = "autodemo_%s@burjex.test" % get_random_string(6).lower()
user = User.objects.create_user(
    username=email.split("@")[0],
    email=email,
    first_name="Auto",
    last_name="Demo",
    password=get_random_string(12),
    role=User.Roles.CLIENT,
)
print("NEW", user.pk, user.email)
creds = provision_signup_demo_account(user)
print("CREDS", creds)
print("COUNTS", MT5Account.objects.filter(user=user).count(), TradingAccount.objects.filter(user=user).count())
print("PROOF_OK" if creds else "PROOF_FAIL")
