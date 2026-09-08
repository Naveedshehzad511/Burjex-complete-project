from django.urls import path

from . import views

urlpatterns = [
    path("funnel/", views.sales_funnel_hub, name="sales-funnel"),
    path("funnel/stage/<str:stage_key>/", views.sales_funnel_stage, name="sales-funnel-stage"),
    path("funnel/action/", views.sales_funnel_action, name="sales-funnel-action"),
    path("dashboard/", views.sales_dashboard, name="sales-dashboard"),
    path("dashboard", views.sales_dashboard, name="sales-dashboard-ns"),
    path(
        "api/manager-target-progress/",
        views.sales_manager_target_progress_api,
        name="sales-manager-target-progress-api",
    ),
    path("ib-analytics/", views.sales_ib_analytics, name="sales-ib-analytics"),
    path("ib/<int:ib_id>/", views.sales_ib_detail, name="sales-ib-detail"),
    path("ib/<int:ib_id>/export/csv/", views.sales_ib_detail_export_csv, name="sales-ib-export-csv"),
    path("ib/<int:ib_id>/export/excel/", views.sales_ib_detail_export_excel, name="sales-ib-export-excel"),
    path("ib/<int:ib_id>/export/pdf/", views.sales_ib_detail_export_pdf, name="sales-ib-export-pdf"),
    path("sales-team/", views.sales_team, name="sales-team"),
    path("revenue/", views.sales_revenue_hub, name="sales-revenue"),
    path("performance/", views.sales_performance_hub, name="sales-performance"),
    path("leads/", views.sales_leads, name="sales-leads"),
    path("clients/", views.sales_clients, name="sales-clients"),
    path("follow-ups/", views.sales_follow_ups, name="sales-follow-ups"),
    path("conversions/", views.sales_conversions, name="sales-conversions"),
    path("reports/", views.sales_reports_hub, name="sales-reports"),
    path("targets/", views.sales_targets, name="sales-targets"),
    path("commission/", views.sales_commission_hub, name="sales-commission"),
    path("activity/", views.sales_activity_log, name="sales-activity-log"),
]
