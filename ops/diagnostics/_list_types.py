
from admin_panel.models import TradingAccountType, DemoAccountSettings
from user_portal.views import _open_account_type_supports_btrader, _resolve_btrader_group, _btrader_client_open_enabled
print("BTRADER_OPEN", _btrader_client_open_enabled())
cfg = DemoAccountSettings.get_solo()
print("DEMO_CFG", cfg.auto_create_on_signup, cfg.default_balance, cfg.default_leverage, getattr(cfg.default_account_type,"id",None), getattr(cfg.default_account_type,"account_name",None))
for t in TradingAccountType.objects.filter(is_active=True).select_related("crm_group","demo_group").order_by("id"):
    cat = getattr(t,"account_category","LIVE")
    demo_ok = (cat=="DEMO") or (cat=="LIVE" and getattr(t,"demo_enabled",False))
    bt = _open_account_type_supports_btrader(t)
    g = _resolve_btrader_group(t, is_demo=True, demo_settings=cfg)
    print(f"TYPE id={t.id} name={t.account_name!r} cat={cat} demo_enabled={getattr(t,'demo_enabled',None)} bt={bt} demo_group={getattr(g,'id',None)}/{getattr(g,'platform',None)}/{getattr(g,'platform_group_name',None) or getattr(g,'name',None)} crm_group={getattr(getattr(t,'crm_group',None),'platform',None)}")
