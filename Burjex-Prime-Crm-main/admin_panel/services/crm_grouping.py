from __future__ import annotations


def ensure_professional_crm_grouping() -> None:
    """No-op: legacy auto-seeding was removed.

    CRM account types, MT5 / Match-Trader group catalogs, trading symbols, and IB commission
    data are created only through admin UI. Kept so existing imports and call sites stay valid.
    """
    return
