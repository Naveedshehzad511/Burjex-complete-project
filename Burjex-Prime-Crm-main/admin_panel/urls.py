from django.urls import include, path
from django.views.generic.base import RedirectView

from enterprise import admin_views as enterprise_views
from live_chat import views as live_chat_views
from email_notifications import admin_views as notif_views

from . import email_management_views as email_mgmt
from . import email_template_system_views as email_tpl_sys
from . import ib_levels_views
from . import ib_application_views
from . import kyc_review_views
from . import org_legal_platform_views
from . import operations_views
from . import risk_monitor_views
from . import symbol_admin_views
from . import tag_management_views
from . import integrations_views
from . import match_trader_views
from . import report_hub_views
from . import trading_platform_views
from . import views
from . import dashboard_hub_views
from . import security_views
from . import user_management_views as um
from . import white_label_views
from .settings import views as settings_views
from . import crm_org_views
from . import account_manager_views

urlpatterns = [
    # Dashboard
    path("dashboard/", views.dashboard, name="admin-dashboard"),
    path(
        "dashboard/live-stats/",
        views.dashboard_live_stats_api,
        name="admin-dashboard-live-stats",
    ),
    path(
        "dashboard/live-activity/",
        views.dashboard_live_activity_api,
        name="admin-dashboard-live-activity",
    ),
    path(
        "dashboard/notifications/<int:notification_id>/read/",
        views.mark_staff_notification_read,
        name="admin-mark-staff-notification-read",
    ),
    path(
        "dashboard/notifications/live/",
        views.dashboard_notifications_api,
        name="admin-dashboard-notifications-api",
    ),
    path(
        "dashboard/notifications/<int:notification_id>/mark-read/",
        views.mark_staff_notification_read_api,
        name="admin-staff-notification-mark-read-api",
    ),
    path(
        "dashboard/notifications/mark-all-read/",
        views.mark_all_staff_notifications_read,
        name="admin-staff-notifications-mark-all-read",
    ),
    path(
        "dashboard/hub/users-activity/",
        dashboard_hub_views.hub_users_activity,
        name="admin-hub-users-activity",
    ),
    path(
        "dashboard/hub/deposits/",
        dashboard_hub_views.hub_deposits,
        name="admin-hub-deposits",
    ),
    path(
        "dashboard/hub/withdrawals/",
        dashboard_hub_views.hub_withdrawals,
        name="admin-hub-withdrawals",
    ),
    path(
        "dashboard/hub/net-revenue/",
        dashboard_hub_views.hub_net_revenue,
        name="admin-hub-net-revenue",
    ),
    path(
        "dashboard/hub/mt5-accounts/",
        dashboard_hub_views.hub_mt5_accounts,
        name="admin-hub-mt5-accounts",
    ),
    path("dashboard", views.dashboard, name="admin-dashboard-ns"),
    path("", views.dashboard, name="admin-dashboard-home"),
    path(
        "crm/sales-dashboard/",
        RedirectView.as_view(pattern_name="sales-dashboard", permanent=False),
        name="admin-sales-dashboard",
    ),
    path("crm/org/departments/", crm_org_views.crm_departments_list, name="admin-crm-departments"),
    path("crm/org/departments/add/", crm_org_views.crm_department_edit, name="admin-crm-department-add"),
    path(
        "crm/org/departments/<int:pk>/edit/",
        crm_org_views.crm_department_edit,
        name="admin-crm-department-edit",
    ),
    path("crm/org/sales-managers/", crm_org_views.crm_sales_managers_list, name="admin-crm-sales-managers"),
    path(
        "crm/org/sales-managers/add/",
        crm_org_views.crm_sales_manager_create,
        name="admin-crm-sales-manager-add",
    ),
    path(
        "crm/org/sales-managers/<int:pk>/edit/",
        crm_org_views.crm_sales_manager_edit,
        name="admin-crm-sales-manager-edit",
    ),
    path(
        "crm/org/sales-managers/<int:pk>/assign-clients/candidates/",
        crm_org_views.crm_sales_manager_assign_clients_candidates,
        name="admin-crm-sales-manager-assign-candidates",
    ),
    path(
        "crm/org/sales-managers/<int:pk>/assign-clients/",
        crm_org_views.crm_sales_manager_assign_clients_submit,
        name="admin-crm-sales-manager-assign-clients",
    ),
    path(
        "crm/org/account-managers/",
        account_manager_views.account_managers_list,
        name="admin-account-managers",
    ),
    path(
        "crm/org/account-managers/add/",
        account_manager_views.account_manager_create,
        name="admin-account-manager-add",
    ),
    path(
        "crm/org/account-managers/<int:pk>/edit/",
        account_manager_views.account_manager_edit,
        name="admin-account-manager-edit",
    ),
    path("crm/org/roles/", crm_org_views.crm_roles_list, name="admin-crm-roles"),
    path("crm/org/roles/add/", crm_org_views.crm_role_create, name="admin-crm-role-add"),
    path("crm/org/roles/<int:pk>/delete/", crm_org_views.crm_role_delete, name="admin-crm-role-delete"),
    path(
        "crm/org/roles/<int:pk>/permissions/",
        crm_org_views.crm_role_edit_grants,
        name="admin-crm-role-permissions",
    ),
    path("crm/org/permissions/", crm_org_views.crm_permissions_hub, name="admin-crm-permissions"),
    path("crm/dashboard-settings/", views.dashboard_settings, name="admin-dashboard-settings"),
    path("crm/account-management/", views.account_management, name="admin-account-management"),
    path("crm/group-management/", views.mt5_groups_admin, name="admin-groups"),
    path("crm/group-management/add/", views.mt5_groups_admin, name="admin-group-add"),
    path("crm/group-management/list/", views.mt5_groups_admin, name="admin-group-list"),
    path("crm/group-management/edit/", views.mt5_groups_admin, name="admin-group-edit"),
    path("crm/group-management/<int:pk>/delete/", views.mt5_group_delete, name="admin-group-delete"),
    path(
        "crm/group-management/platform-groups.json",
        views.mt5_platform_groups_json,
        name="admin-crm-platform-groups-json",
    ),
    path(
        "crm/group-management/symbols.json",
        symbol_admin_views.crm_group_symbols_json,
        name="admin-crm-group-symbols-json",
    ),
    path(
        "crm/group-management/match-trader-groups/",
        views.match_trader_broker_groups_admin,
        name="admin-match-trader-broker-groups",
    ),
    path("system-management/group-management/", views.group_management, name="system-management-group-management"),
    path("crm/account-management/account-types/", views.trading_account_settings, name="admin-account-types"),
    path("crm/account-management/account-types/add/", views.trading_account_settings, name="admin-account-type-add"),
    path("crm/account-management/account-types/list/", views.trading_account_settings, name="admin-account-type-list"),
    path("crm/account-management/account-types/edit/", views.trading_account_settings, name="admin-account-type-edit"),
    path("system-management/account-types/", views.account_types, name="system-management-account-types"),
    path("crm/account-management/trading-account-settings/", views.trading_account_settings, name="admin-trading-account-settings"),
    path("crm/account-management/demo-settings/", views.demo_account_settings, name="admin-demo-account-settings"),
    path("crm/account-management/trading-accounts/", views.trading_accounts, name="admin-trading-accounts"),
    path("crm/account-management/trading-account-requests/", views.trading_account_requests, name="admin-trading-account-requests"),
    path("crm/symbol-groups/", symbol_admin_views.symbol_groups_admin, name="admin-symbol-groups"),
    path("crm/trading-symbols/", symbol_admin_views.trading_symbols_admin, name="admin-trading-symbols"),
    path(
        "crm/trading-symbols/sample/",
        symbol_admin_views.trading_symbols_export_sample,
        name="admin-trading-symbols-sample",
    ),
    path(
        "crm/broker-crm-commission/",
        symbol_admin_views.broker_crm_commission_toggle,
        name="admin-broker-crm-commission",
    ),

    # Client portal white label (System Management)
    path("system/white-label/", white_label_views.white_label_hub, name="admin-white-label-hub"),
    path("system/white-label/theme/", white_label_views.white_label_theme, name="admin-white-label-theme"),
    path("system/white-label/branding/", white_label_views.white_label_branding, name="admin-white-label-branding"),
    path("system/white-label/layout/", white_label_views.white_label_layout, name="admin-white-label-layout"),
    path("system/white-label/profiles/", white_label_views.white_label_profiles, name="admin-white-label-profiles"),

    # System Management dashboard + modular settings routes
    path("system-management/", settings_views.system_management_dashboard, name="admin-system-management-dashboard"),
    path("system-management/email-templates/", email_tpl_sys.email_templates_system_list, name="admin-system-email-templates"),
    path("system-management/email-templates/new/", email_tpl_sys.email_template_system_create, name="admin-system-email-templates-create"),
    path(
        "system-management/email-templates/<int:pk>/edit/",
        email_tpl_sys.email_template_system_edit,
        name="admin-system-email-templates-edit",
    ),
    path(
        "system-management/email-templates/<int:pk>/status/",
        email_tpl_sys.email_template_system_toggle_status,
        name="admin-system-email-templates-toggle-status",
    ),
    path(
        "system-management/email-templates/<int:pk>/delete/",
        email_tpl_sys.email_template_system_delete,
        name="admin-system-email-templates-delete",
    ),
    path(
        "system-management/email-templates/<int:pk>/preview/",
        email_tpl_sys.email_template_system_preview,
        name="admin-system-email-templates-preview",
    ),
    path("system-management/email-templates/layout/", email_tpl_sys.email_global_layout_edit, name="admin-system-email-layout"),
    path(
        "system-management/email-purposes/",
        email_tpl_sys.email_purposes_system_manage,
        name="admin-system-email-purposes",
    ),
    path(
        "system-management/email-templates/preview-draft/",
        email_tpl_sys.email_template_preview_draft,
        name="admin-system-email-templates-preview-draft",
    ),
    path("system-management/integrations/", integrations_views.integrations_hub, name="admin-integrations-hub"),
    path("system-management/integrations/ai/", integrations_views.integrations_ai, name="admin-integrations-ai"),
    path(
        "system-management/integrations/ai/test/<slug:slug>/",
        integrations_views.integrations_ai_test,
        name="admin-integrations-ai-test",
    ),
    path("system-management/integrations/compliance/", integrations_views.integrations_compliance, name="admin-integrations-compliance"),
    path(
        "system-management/integrations/compliance/<slug:provider>/",
        integrations_views.integrations_compliance_edit,
        name="admin-integrations-compliance-edit",
    ),
    path("system-management/integrations/support/", integrations_views.integrations_support, name="admin-integrations-support"),
    path("system-management/integrations/email-sms/", integrations_views.integrations_email_sms, name="admin-integrations-email-sms"),
    path(
        "system-management/integrations/email-sms/<slug:provider_key>/",
        integrations_views.integrations_email_provider,
        name="admin-integrations-email-provider",
    ),
    path(
        "system-management/integrations/sms/<slug:provider_key>/",
        integrations_views.integrations_sms_provider,
        name="admin-integrations-sms-provider",
    ),
    path(
        "integrations/match-trader/save/",
        match_trader_views.match_trader_api_save,
        name="admin-integrations-match-trader-save",
    ),
    path(
        "integrations/match-trader/test/",
        match_trader_views.match_trader_api_test,
        name="admin-integrations-match-trader-test",
    ),
    path(
        "integrations/match-trader/activate/",
        match_trader_views.match_trader_api_activate,
        name="admin-integrations-match-trader-activate",
    ),
    path(
        "integrations/match-trader/deactivate/",
        match_trader_views.match_trader_api_deactivate,
        name="admin-integrations-match-trader-deactivate",
    ),
    path(
        "integrations/match-trader/reset/",
        match_trader_views.match_trader_api_reset,
        name="admin-integrations-match-trader-reset",
    ),
    path(
        "integrations/match-trader/map-groups/",
        match_trader_views.match_trader_api_map_groups,
        name="admin-integrations-match-trader-map-groups",
    ),
    path(
        "integrations/match-trader/sync-catalog/",
        match_trader_views.match_trader_api_sync_catalog,
        name="admin-integrations-match-trader-sync-catalog",
    ),
    path(
        "integrations/match-trader/test-groups-sync/",
        match_trader_views.match_trader_api_test_groups_sync,
        name="admin-integrations-match-trader-test-groups-sync",
    ),
    path(
        "system-management/integrations/trading-platforms/match-trader/",
        match_trader_views.match_trader_enterprise_page,
        name="admin-integrations-match-trader-enterprise",
    ),
    path(
        "system-management/trading-monitor/match-trader/",
        match_trader_views.match_trader_trading_monitor,
        name="admin-trading-monitor-match-trader",
    ),
    path(
        "integrations/matchtrader/test/",
        match_trader_views.matchtrader_test_connection,
        name="admin-integrations-matchtrader-test-legacy",
    ),
    path(
        "system-management/integrations/trading-platforms/",
        trading_platform_views.trading_platforms_hub,
        name="admin-integrations-trading-platforms-hub",
    ),
    path(
        "system-management/integrations/trading/",
        RedirectView.as_view(pattern_name="admin-integrations-trading-platforms-hub", permanent=False),
        name="admin-integrations-trading",
    ),
    path("system-management/integrations/recaptcha/", integrations_views.integrations_recaptcha, name="admin-integrations-recaptcha"),
    path("system-management/integrations/social-login/", integrations_views.integrations_social_login, name="admin-integrations-social-login"),
    path("system-management/integrations/google-2fa/", integrations_views.integrations_google_2fa, name="admin-integrations-google-2fa"),
    path("system-management/integrations/match2pay/", integrations_views.integrations_match2pay, name="admin-integrations-match2pay"),
    path(
        "system-management/integrations/match2pay/webhook/",
        integrations_views.match2pay_webhook_stub,
        name="admin-integrations-match2pay-webhook",
    ),
    path("system-management/integrations/logs/", integrations_views.integrations_logs, name="admin-integrations-logs"),
    path("system-management/tag-system/", tag_management_views.tag_system, name="admin-tag-system"),
    path("system-management/branding/", views.branding, name="system-management-branding"),
    path("system-management/logo-upload/", views.logo_upload, name="system-management-logo-upload"),
    path("settings/", include("admin_panel.settings.urls")),
    path("settings/compliance/", views.compliance_settings, name="admin-compliance-settings"),
    path("settings/treasury/", views.treasury_hub, name="admin-treasury-hub"),
    path("settings/treasury/deposit-methods/", views.payment_gateways, {"treasury_scope": "DEPOSIT"}, name="admin-treasury-deposit-methods"),
    path("settings/treasury/withdrawal-methods/", views.payment_gateways, {"treasury_scope": "WITHDRAW"}, name="admin-treasury-withdraw-methods"),
    path("settings/treasury/wallet/", views.treasury_wallet_settings, name="admin-treasury-wallet-settings"),
    path("settings/treasury/transfer/", views.treasury_transfer_settings, name="admin-treasury-transfer-settings"),
    path("organization/profile/", org_legal_platform_views.organization_profile_settings, name="admin-organization-profile"),
    path(
        "settings/trading-platforms/",
        RedirectView.as_view(pattern_name="admin-integrations-trading-platforms-hub", permanent=False),
        name="admin-trading-platforms-hub",
    ),
    path(
        "settings/trading-platforms/<slug:slug>/configure/",
        trading_platform_views.trading_platform_configure,
        name="admin-trading-platform-configure",
    ),
    path(
        "settings/trading-platforms/<slug:slug>/test-connection/",
        trading_platform_views.trading_platform_test_ajax,
        name="admin-trading-platform-test",
    ),
    path("compliance/reviews/", views.compliance_reviews, name="admin-compliance-reviews"),
    path("compliance/desk/", operations_views.compliance_desk, name="admin-compliance-desk"),
    path("compliance/desk/live/", operations_views.compliance_desk_live, name="admin-compliance-desk-live"),
    path("integrations/customer-support/", operations_views.support_integrations_admin, name="admin-support-integrations"),
    path("system/email-sms/", operations_views.email_sms_management, name="admin-email-sms"),
    path("user-kyc/<int:id>/", views.view_kyc, name="admin-user-kyc-view"),
    path("users/kyc-review/<int:user_id>/", kyc_review_views.kyc_review, name="admin-kyc-review"),

    # User Management (custom CRM UI — not Django admin)
    path("users/add/", um.um_add_user, name="admin-user-add"),
    path("users/list/", um.um_user_list, name="admin-user-list"),
    path("users/account-approval/", um.um_account_approval, name="admin-account-approval"),
    path("users/activity/", um.um_user_activity, name="admin-user-activity"),
    path("users/<int:pk>/block-toggle/", um.um_user_block_toggle, name="admin-user-block-toggle"),
    path("users/<int:pk>/view/", um.um_user_view, name="admin-user-view"),
    path("users/<int:pk>/edit/", um.um_user_edit, name="admin-user-edit"),
    path("users/<int:pk>/delete/", um.um_user_delete, name="admin-user-delete"),
    path("users/<int:pk>/promote-ib/", um.um_promote_ib, name="admin-user-promote-ib"),
    path("users/<int:pk>/quick-action/", um.um_user_quick_action, name="admin-user-quick-action"),
    path("users/<int:pk>/tags/assign/", tag_management_views.user_tag_assign, name="admin-user-tag-assign"),
    path("users/<int:pk>/tags/<int:user_tag_id>/remove/", tag_management_views.user_tag_remove, name="admin-user-tag-remove"),
    path("settings/status-badges/", um.um_status_badge_settings, name="admin-status-badge-settings"),
    path("users/mt5/create-account/", um.um_create_mt5, name="admin-mt5-create"),
    path("users/mt5/list/", um.um_mt5_list, name="admin-mt5-list"),
    # Follow Up List page disabled; User List now includes the follow-up filters.
    # path("users/follow-up/", um.um_follow_up_list, name="admin-follow-up"),
    path("users/documents/pending/", um.um_pending_documents_users, name="admin-docs-pending"),
    path("kyc/documents/", um.um_pending_documents_users, name="admin-kyc-documents"),
    path("users/documents/approved/", um.um_documents_approved, name="admin-docs-approved"),
    path(
        "users/documents/rejected/",
        RedirectView.as_view(url="/admin/users/documents/pending/?status=rejected", permanent=False),
        name="admin-docs-rejected",
    ),
    path("users/documents/expired-report/", um.um_documents_expired, name="admin-docs-expired"),
    path("users/documents/all/", um.um_documents_all, name="admin-docs-all"),
    path("users/documents/upload/", um.um_upload_documents, name="admin-docs-upload"),
    path("users/bank-details/add/", um.um_bank_add, name="admin-bank-add"),
    path("users/bank-details/list/", um.um_bank_list, name="admin-bank-list"),
    path("users/password/change-user/", um.um_change_user_password, name="admin-change-user-password"),
    path("users/password/list/", um.um_password_list, name="admin-user-password-list"),
    path("users/password/change-mt5/", um.um_change_mt5_password, name="admin-change-mt5-password"),
    path("users/mt5/update-leverage/", um.um_update_mt5_leverage, name="admin-mt5-update-leverage"),
    path("users/existing-client/add/", um.um_add_existing_client, name="admin-user-add-existing-client"),
    path("users/resend-verification/", um.um_resend_verification, name="admin-resend-verification"),

    # Bonus
    path("bonus/manage/", views.bonus_management, name="admin-bonus-manage"),
    path("bonus/give/", views.bonus_management, name="admin-bonus-give"),
    path("bonus/remove/", views.bonus_management, name="admin-bonus-remove"),
    path("bonus/list/", views.bonus_management, name="admin-bonus-list"),
    path("bonus/assign/", views.bonus_management, name="admin-bonus-assign"),
    path("bonus/rules/", views.bonus_management, name="admin-bonus-rules"),
    path("bonus/deposit/", views.bonus_management, name="admin-bonus-deposit"),

    # IB Management
    path("ib/levels/", ib_levels_views.ib_levels_dashboard, name="admin-ib-levels"),
    path("ib/levels/add/", ib_levels_views.ib_level_add, name="admin-ib-level-add"),
    path("ib/levels/<int:pk>/edit/", ib_levels_views.ib_level_edit, name="admin-ib-level-edit"),
    path("ib/levels/<int:pk>/delete/", ib_levels_views.ib_level_delete, name="admin-ib-level-delete"),
    path("ib/levels/approval/", ib_levels_views.ib_level_approval_queue, name="admin-ib-level-approval"),
    path("ib/dashboard/", views.ib_dashboard, name="admin-ib-dashboard"),
    path("ib/users/", views.ib_users, name="admin-ib-users"),
    path("ib/users/<int:ib_id>/tree/", views.admin_ib_tree, name="admin-ib-tree"),
    path("ib/requests/", views.ib_requests_page, name="admin-ib-requests"),
    path("ib/plan/", views.ib_plan_page, name="admin-ib-plan"),
    path("ib/plan/add/", views.ib_plan_page, name="admin-ib-plan-add"),
    path("ib/commission-group/", views.ib_commission_group_page, name="admin-ib-commission-group"),
    path("ib/add-commission-group/", views.add_commission_group, name="add_commission_group"),
    path("ib/set-commission/", views.ib_set_commission_page, name="admin-ib-set-commission"),
    path("ib/trade-close-event/", views.ib_trade_close_event, name="admin-ib-trade-close-event"),

    path("ib/move-client/", views.ib_move_client_page, name="admin-ib-move-client"),
    path("ib/commission-report/", views.ib_commission_report_page, name="admin-ib-commission-report"),
    path("ib/withdrawals/", views.admin_ib_withdrawals, name="admin-ib-withdrawals"),
    path("ib/adjustments/", views.admin_manual_rebate_adjustment, name="admin-manual-rebate-adjustment"),
    path("ib/trigger-sync/", views.admin_trigger_rebate_sync, name="admin-trigger-rebate-sync"),
    path("ib/settings/application-form/", ib_application_views.ib_application_form_settings, name="admin-ib-application-form"),
    path("ib/settings/application-form/add/", ib_application_views.ib_application_question_add, name="admin-ib-application-form-add"),
    path("ib/settings/application-form/<int:pk>/edit/", ib_application_views.ib_application_question_edit, name="admin-ib-application-form-edit"),
    path("ib/settings/application-form/<int:pk>/delete/", ib_application_views.ib_application_question_delete, name="admin-ib-application-form-delete"),
    path("ib/trade-simulator/", symbol_admin_views.trade_simulator_admin, name="admin-ib-trade-simulator"),
    path("ib/commission-matrix/", symbol_admin_views.ib_commission_matrix_admin, name="admin-ib-commission-matrix"),

    # Group Management (legacy paths redirected to consolidated module)
    path("groups/add/", RedirectView.as_view(pattern_name="admin-group-add", permanent=False), name="admin-group-add-legacy"),
    path("groups/list/", RedirectView.as_view(pattern_name="admin-group-list", permanent=False), name="admin-group-list-legacy"),

    # Transaction
    path("transactions/client-deposit/", views.placeholder_page, {"title": "Client Deposit"}, name="admin-client-deposit"),
    path("transactions/client-withdraw/", views.placeholder_page, {"title": "Client Withdraw"}, name="admin-client-withdraw"),
    path("transactions/wallet-deposit/", views.placeholder_page, {"title": "Wallet Deposit"}, name="admin-wallet-deposit"),
    path("transactions/wallet-withdraw/", views.placeholder_page, {"title": "Wallet Withdraw"}, name="admin-wallet-withdraw"),
    path("transactions/ib-withdraw/", views.admin_ib_withdrawals, name="admin-ib-withdraw"),
    path("transactions/internal-transfer/", views.transfers_admin, name="admin-transfers"),
    path("transactions/pending-deposit/", views.pending_deposit, name="admin-pending-deposit"),
    path("transactions/pending-withdraw/", views.pending_withdraw, name="admin-pending-withdraw"),
    # Reports module routes
    path("reports/", report_hub_views.reports_dashboard, name="admin-reports-dashboard"),
    path("reports/financial/deposit/", views.payment_requests, name="admin-report-deposit"),
    path("reports/financial/withdrawal/", views.payment_requests, name="admin-report-withdrawal"),
    path("reports/financial/ib-commission/", views.ib_commission_report_page, name="admin-report-ib-commission"),
    path("reports/financial/transactions/", views.report_history, name="admin-report-transactions"),
    path("reports/client/clients/", um.um_user_list, name="admin-report-clients"),
    path("reports/client/active-traders/", views.placeholder_page, {"title": "Active Traders Report"}, name="admin-report-active-traders"),
    path("reports/ib/performance/", views.placeholder_page, {"title": "IB Performance Report"}, name="admin-report-ib-performance"),
    path("reports/ib/withdrawal/", views.placeholder_page, {"title": "IB Withdrawal Report"}, name="admin-report-ib-withdrawal"),
    path("reports/ib/clients/", views.ib_users, name="admin-report-ib-clients"),
    path("reports/trading/volume/", views.placeholder_page, {"title": "Trading Volume Report"}, name="admin-report-trading-volume"),
    path("reports/trading/accounts/", views.trading_accounts, name="admin-report-account"),
    path("reports/trading/mt5/", views.report_position, name="admin-report-mt5-trading"),
    # Transactions -> Deposits (organized structure) — routes centralized under Settings → Treasury
    path("transactions/deposits/methods/", RedirectView.as_view(pattern_name="admin-treasury-deposit-methods", permanent=False), name="admin-tx-deposit-methods"),
    path("transactions/deposits/settings/", RedirectView.as_view(pattern_name="admin-treasury-hub", permanent=False), name="admin-tx-deposit-settings"),
    path("transactions/deposits/requests/", views.payment_requests, name="admin-tx-deposit-requests"),
    # Transactions -> Withdrawals (organized structure)
    path("transactions/withdrawals/methods/", RedirectView.as_view(pattern_name="admin-treasury-withdraw-methods", permanent=False), name="admin-tx-withdraw-methods"),
    path("transactions/withdrawals/settings/", RedirectView.as_view(pattern_name="admin-treasury-hub", permanent=False), name="admin-tx-withdraw-settings"),
    path("transactions/withdrawals/requests/", views.payment_requests, name="admin-tx-withdraw-requests"),

    # Marketing
    path("marketing/add/", views.placeholder_page, {"title": "Add Marketing"}, name="admin-marketing-add"),
    path("marketing/list/", views.placeholder_page, {"title": "Marketing List"}, name="admin-marketing-list"),
    path("marketing/incentive-report/", views.placeholder_page, {"title": "Incentive Report"}, name="admin-incentive-report"),
    path("marketing/withdraw-report/", views.placeholder_page, {"title": "Marketing Withdraw Report"}, name="admin-marketing-withdraw-report"),
    path("marketing/bulk-lead-upload/", views.placeholder_page, {"title": "Bulk Lead Upload"}, name="admin-bulk-lead-upload"),
    path("marketing/leads/list/", views.placeholder_page, {"title": "Lead List"}, name="admin-lead-list"),

    # Copier
    path("copier/accounts/", views.placeholder_page, {"title": "Copy Trading Accounts"}, name="admin-copier-accounts"),
    path("copier/management/", views.placeholder_page, {"title": "Copier Management"}, name="admin-copier-management"),
    path("copier/all-rules/", views.placeholder_page, {"title": "All Rules"}, name="admin-copier-all-rules"),
    path("copier/symbol-translations/", views.placeholder_page, {"title": "Symbol Translations"}, name="admin-copier-symbol-translations"),
    path("copier/assign-rules/", views.placeholder_page, {"title": "Assign Rules"}, name="admin-copier-assign-rules"),
    path("copier/connection-requests/", views.placeholder_page, {"title": "Connection Request List"}, name="admin-copier-connection-requests"),
    path("copier/connections/", views.placeholder_page, {"title": "Connection List"}, name="admin-copier-connections"),

    # Send Email
    path("email/send/", views.email_send_page, name="admin-send-email"),
    path("email/management/", email_mgmt.email_management_hub, name="admin-email-management"),
    path(
        "email/management/template/<str:event_key>/edit/",
        email_mgmt.email_template_edit,
        name="admin-email-template-edit",
    ),
    path("email/templates/", email_mgmt.email_management_hub, name="admin-email-templates"),
    path("email/inbox/", email_mgmt.email_inbox_page, name="admin-email-inbox"),
    path("email/bulk/", views.email_bulk_page, name="admin-bulk-email"),
    path("email/history/", views.email_history_page, name="admin-email-history"),

    # Notification email system (email_notifications app)
    path("email/notifications/settings/", notif_views.notification_settings, name="admin-notification-email-settings"),
    path("email/notifications/templates/", notif_views.notification_templates_list, name="admin-notification-templates"),
    path("email/notifications/templates/add/", notif_views.notification_template_edit, name="admin-notification-template-add"),
    path("email/notifications/templates/<int:pk>/edit/", notif_views.notification_template_edit, name="admin-notification-template-edit"),
    path("email/notifications/templates/<int:pk>/test/", notif_views.notification_template_send_test, name="admin-notification-template-test"),
    path("email/notifications/templates/<int:pk>/preview/", notif_views.notification_template_preview, name="admin-notification-template-preview"),
    path("email/notifications/logs/", notif_views.notification_logs, name="admin-notification-logs"),

    # News
    path("news/add/", views.placeholder_page, {"title": "Add News"}, name="admin-news-add"),
    path("news/list/", views.placeholder_page, {"title": "News List"}, name="admin-news-list"),

    # Notification
    path("notifications/push/", views.placeholder_page, {"title": "Push Notification"}, name="admin-push-notification"),
    path("notifications/history/", views.placeholder_page, {"title": "Notification History"}, name="admin-notification-history"),
    path("settings/security/maintenance/", security_views.maintenance_settings_page, name="admin-maintenance-settings"),
    path("settings/security/", security_views.maintenance_settings_page, name="admin-security-settings"),
    path("sidebar-settings/", views.admin_sidebar_settings, name="admin-sidebar-settings"),
    path("profile/", views.admin_profile_page, name="admin-profile"),
    path("profile/password-change/", views.AdminProfilePasswordChangeView.as_view(), name="admin-profile-password-change"),
    path("settings/notifications/", views.placeholder_page, {"title": "Notification Settings"}, name="admin-notification-settings"),
    path("administration/admin-users/", views.sub_admin_users_page, name="admin-admin-users"),
    path("settings/staff/", views.sub_admin_users_page, name="admin-settings-staff"),
    path("settings/roles/", views.role_management_page, name="admin-settings-roles"),
    path("administration/roles-permissions/", views.role_management_page, name="admin-roles-permissions"),
    path("administration/access-control/", views.permission_management_page, name="admin-access-control"),
    path("administration/activity-logs/", views.placeholder_page, {"title": "Activity Logs"}, name="admin-activity-logs"),
    path("tools/campaign-management/", views.placeholder_page, {"title": "Campaign Management"}, name="admin-campaign-management"),
    path("notifications/unread/", views.placeholder_page, {"title": "Unread Notification"}, name="admin-notification-unread"),
    path("notifications/read/", views.placeholder_page, {"title": "Read Notification"}, name="admin-notification-read"),
    path(
        "reports/login-activity/",
        RedirectView.as_view(pattern_name="admin-enterprise-login-events", permanent=False),
        name="admin-report-login-activity",
    ),
    path("enterprise/health/", enterprise_views.enterprise_system_health, name="admin-enterprise-health"),
    path("enterprise/audit/", enterprise_views.enterprise_audit_log, name="admin-enterprise-audit"),
    path("enterprise/risk/", enterprise_views.enterprise_risk_desk, name="admin-enterprise-risk"),
    path("enterprise/risk/<int:pk>/", enterprise_views.enterprise_risk_profile_edit, name="admin-enterprise-risk-edit"),
    path("enterprise/security/", enterprise_views.enterprise_security_settings, name="admin-enterprise-security-settings"),
    path("enterprise/login-events/", enterprise_views.enterprise_login_events, name="admin-enterprise-login-events"),
    path("enterprise/staff-alerts/", enterprise_views.enterprise_staff_notifications, name="admin-enterprise-staff-notifications"),
    path("settings/chat/", live_chat_views.admin_chat_settings, name="admin-chat-settings"),
    path("tickets/", live_chat_views.admin_tickets_dashboard, name="admin-tickets"),
    path(
        "tickets/<int:conversation_id>/send/",
        live_chat_views.admin_send_message,
        name="admin-chat-send-message",
    ),
    path(
        "tickets/<int:ticket_id>/status/",
        live_chat_views.admin_ticket_update_status,
        name="admin-ticket-update-status",
    ),
    path("settings/deposit-bank-details/", views.placeholder_page, {"title": "Deposit Bank Details"}, name="admin-setting-deposit-bank-details"),
    path("settings/promotion-list/", views.placeholder_page, {"title": "Promotion List"}, name="admin-setting-promotion-list"),
    path("settings/psp/", views.placeholder_page, {"title": "PSP Setting"}, name="admin-setting-psp"),
    path("settings/default/", views.placeholder_page, {"title": "Default Setting"}, name="admin-setting-default"),
    path("settings/ib-request-terms/", views.placeholder_page, {"title": "IB Request Terms"}, name="admin-setting-ib-request-terms"),
    path("analytics/", report_hub_views.analytics_dashboard, name="admin-analytics-dashboard"),
    path("analytics/clients/", report_hub_views.analytics_clients, name="admin-analytics-clients"),
    path("analytics/deposits/", report_hub_views.analytics_deposits, name="admin-analytics-deposits"),
    path("analytics/withdrawals/", report_hub_views.analytics_withdrawals, name="admin-analytics-withdrawals"),
    path("analytics/ib/", views.placeholder_page, {"title": "IB Analytics"}, name="admin-analytics-ib"),
    path("analytics/revenue/", report_hub_views.analytics_revenue, name="admin-analytics-revenue"),
    path("analytics/risk-monitor/", risk_monitor_views.risk_monitor_dashboard, name="admin-risk-monitor"),
    path("analytics/risk-monitor/positions/", risk_monitor_views.risk_monitor_positions, name="admin-risk-monitor-positions"),
    path("dashboard/export/", views.dashboard_export, name="admin-dashboard-export"),
    path("clients/", views.placeholder_page, {"title": "Clients"}, name="admin-clients"),
    path("ib/", views.placeholder_page, {"title": "IB"}, name="admin-ib-overview"),
    path("compliance/", views.placeholder_page, {"title": "Compliance"}, name="admin-compliance-overview"),
    path("pending-deposits/", views.pending_deposit, name="admin-pending-deposits-alt"),
    path("pending-withdrawals/", views.pending_withdraw, name="admin-pending-withdrawals-alt"),
    path("active-traders/", views.placeholder_page, {"title": "Active Traders"}, name="admin-active-traders"),

    # Payments (full management module)
    path("payments/gateways/", views.legacy_payment_gateways_redirect, name="admin-payment-gateways"),
    path("payments/requests/", views.payment_requests, name="admin-payment-requests"),
]

