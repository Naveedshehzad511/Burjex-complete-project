
from admin_panel.models import TradingAccountType, DemoAccountSettings
from api.services.signup_demo import _pick_demo_account_type
from user_portal.views import _resolve_btrader_group, _build_leverage_options_open_account

t = TradingAccountType.objects.get(id=5)
t.demo_enabled = True
if not getattr(t, "max_demo_accounts", None):
    try:
        t.max_demo_accounts = 5
    except Exception:
        pass
t.save()
print("UPDATED_TYPE", t.id, t.account_name, "demo_enabled=", t.demo_enabled)

cfg = DemoAccountSettings.get_solo()
cfg.auto_create_on_signup = True
cfg.default_account_type = t
cfg.default_balance = cfg.default_balance or 10000
opts = _build_leverage_options_open_account(getattr(t, "max_leverage", 100), getattr(t, "leverage_options", None))
print("LEV_OPTS", opts)
if int(cfg.default_leverage or 0) not in opts:
    cfg.default_leverage = opts[0] if opts else 100
cfg.save()
print("DEMO_CFG", cfg.auto_create_on_signup, cfg.default_balance, cfg.default_leverage, cfg.default_account_type_id)

picked = _pick_demo_account_type(cfg)
print("PICK", getattr(picked,"id",None), getattr(picked,"account_name",None))
g = _resolve_btrader_group(picked, is_demo=True, demo_settings=cfg) if picked else None
print("GROUP", getattr(g,"id",None), getattr(g,"platform_group_name",None) or getattr(g,"name",None))
