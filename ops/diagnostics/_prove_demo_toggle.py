
from admin_panel.models import DemoAccountSettings, TradingAccount
from accounts.models import User, MT5Account
from api.services.signup_demo import provision_signup_demo_account, _pick_demo_account_type
from django.utils.crypto import get_random_string

cfg = DemoAccountSettings.get_solo()
if not cfg.auto_create_on_signup:
    cfg.auto_create_on_signup = True
    cfg.save(update_fields=['auto_create_on_signup'])
    print('ENABLED_AUTO_CREATE')
else:
    print('ALREADY_ENABLED')
print('CFG', cfg.auto_create_on_signup, cfg.default_balance, cfg.default_leverage)
t = _pick_demo_account_type(cfg)
print('PICK', getattr(t,'id',None), getattr(t,'account_name',None))
email = 'autodemo_%s@burjex.test' % get_random_string(6).lower()
user = User.objects.create_user(
    username=email.split('@')[0],
    email=email,
    first_name='Auto',
    last_name='Demo',
    password=get_random_string(12),
    role=User.Roles.CLIENT,
)
print('NEW', user.pk, user.email)
creds = provision_signup_demo_account(user)
print('CREDS', creds)
print('COUNTS', MT5Account.objects.filter(user=user).count(), TradingAccount.objects.filter(user=user).count())
print('PROOF_OK' if creds else 'PROOF_FAIL')
