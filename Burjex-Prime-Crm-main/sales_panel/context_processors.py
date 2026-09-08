"""Feature flags for Sales portal navigation (CRM permission–aware)."""

from __future__ import annotations

from accounts.crm_permissions import (
    SALES_IB_ANALYTICS,
    SALES_TEAM_METRICS,
    SALES_VIEW_FUNNEL,
    SALES_VIEW_LEADS,
    SALES_VIEW_REVENUE_HUB,
    user_has_crm_permission,
)


def sales_portal_feature_flags(request):
    user = getattr(request, "user", None)
    if not user or not user.is_authenticated:
        return {}
    if not getattr(user, "can_access_sales_portal", lambda: False)():
        return {}
    return {
        "sales_can_ib_analytics": user_has_crm_permission(user, SALES_IB_ANALYTICS),
        "sales_can_team_metrics": user_has_crm_permission(user, SALES_TEAM_METRICS),
        "sales_can_revenue_hub": user_has_crm_permission(user, SALES_VIEW_REVENUE_HUB),
        "sales_nav_leads": user_has_crm_permission(user, SALES_VIEW_LEADS),
        "sales_nav_funnel": user_has_crm_permission(user, SALES_VIEW_FUNNEL),
    }
