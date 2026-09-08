"""Derive MT5Group.name and Match-Trader FK from platform + catalog fields."""

from __future__ import annotations

from accounts.models import MT5Group
from admin_panel.models import MatchTraderBrokerGroup


def sync_mt5_group_derived_fields(instance: MT5Group) -> None:
    """
    Called from GroupForm.save(commit=False) before instance.save().
    Sets internal unique `name` and `match_trader_broker_group` from selections.
    """
    platform = instance.platform
    pg = (instance.platform_group_name or "").strip()
    crm = (instance.crm_group_name or "").strip()

    if platform == MT5Group.BrokerPlatform.MATCH_TRADER:
        mtbg = (
            MatchTraderBrokerGroup.objects.filter(name=pg, is_active=True).first()
            if pg
            else None
        )
        instance.match_trader_broker_group = mtbg
        label = "|".join(x for x in (crm, pg) if x)
        instance.name = (label[:120] if label else (pg[:120] if pg else "match-trader"))[:120]
    else:
        instance.match_trader_broker_group = None
        instance.name = (pg[:120] if pg else crm[:120] or "broker-group")[:120]
