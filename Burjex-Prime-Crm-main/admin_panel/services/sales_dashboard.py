"""Legacy metrics for the Main Sales Dashboard (company-level).

Manager- or department-scoped dashboards should use separate views, templates,
and services—do not extend this module or the sales_panel dashboard template for those.
"""

from __future__ import annotations

from marketing.models import Lead


def get_sales_dashboard_context() -> dict:
    total = Lead.objects.count()
    converted = Lead.objects.filter(status=Lead.Status.CONVERTED).count()
    if total:
        rate = round((converted / total) * 100, 1)
        conversion_display = f"{rate}%"
    else:
        conversion_display = "—"
    return {
        "total_leads": total,
        "conversion_rate": conversion_display,
        "activity": "—",
    }
