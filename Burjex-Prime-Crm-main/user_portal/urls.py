from django.urls import path

from . import support_views
from . import views
from . import notification_api

urlpatterns = [
    path("api/notifications/", notification_api.notifications_list_api, name="user-notifications-api"),
    path(
        "api/notifications/<int:pk>/read/",
        notification_api.notification_mark_read_api,
        name="user-notification-mark-read-api",
    ),
    path("api/accounts/positions/", views.dashboard_open_positions_api, name="user-accounts-open-positions-api"),

    path("dashboard/", views.dashboard, name="user-dashboard"),
    path("dashboard", views.dashboard, name="user-dashboard-ns"),
    path("", views.dashboard, name="user-home"),

    # Regulations now maps to full Compliance/KYC module
    path("regulations/", views.compliance_page, name="user-regulations"),

    # My Funds
    path("my-funds/deposit/", views.deposit_feature, name="user-deposit"),
    path("my-funds/withdrawal/", views.withdraw_feature, name="user-withdraw"),
    path("my-funds/internal-transfer/", views.internal_transfer_feature, name="user-internal-transfer"),

    # Wallet
    path("wallet/", views.wallet_page, name="user-wallet"),

    # IB Program
    path("ib-program/dashboard/", views.ib_dashboard_page, name="user-ib-dashboard"),
    path("ib-program/progress/", views.ib_progress_api, name="user-ib-progress-api"),
    path("ib-program/apply/", views.ib_apply_request, name="user-ib-apply"),
    path("ib-program/my-clients/", views.ib_my_clients, name="user-ib-my-clients"),
    path("ib-program/tree/", views.ib_tree_chart, name="user-ib-tree"),
    path("ib-program/commission/", views.ib_commission, name="user-ib-commission"),
    path("ib-program/withdraw/", views.ib_withdraw_report, name="user-ib-withdraw"),
    path("ib-program/withdraw-request/", views.ib_withdraw_request, name="user-ib-withdraw-request"),
    path("ib-program/team-deposit-report/", views.team_deposit_report, name="user-team-deposit-report"),
    path("ib-program/team-withdraw-report/", views.team_withdraw_report, name="user-team-withdraw-report"),

    # My Data
    path("my-data/profile/", views.profile_page, name="user-mydata-profile"),
    path("my-data/documents/", views.my_documents_page, name="user-mydata-documents"),
    path("my-data/verification/", views.verification_page, name="user-mydata-verification"),

    # Reports (kept for CRM compatibility)
    path("my-data/deposit-report/", views.deposit_report, name="user-deposit-report"),
    path("my-data/withdraw-report/", views.withdraw_report, name="user-withdraw-report"),
    path("my-data/internal-transfer-report/", views.internal_transfer_report, name="user-internal-transfer-report"),
    path("my-data/deal-report/", views.deal_report, name="user-deal-report"),
    path("my-data/summary-report/", views.summary_report, name="user-summary-report"),

    # Other sections
    path("compliance/", views.compliance_page, name="user-compliance"),
    path("competition/", views.placeholder_page, {"title": "Competition"}, name="user-competition"),
    path("trade-and-win/", views.placeholder_page, {"title": "Trade & Win"}, name="user-trade-and-win"),
    path("news/", views.placeholder_page, {"title": "News"}, name="user-news"),
    path("support/", support_views.support_page, name="user-support"),
    path("support/<str:ticket_number>/", support_views.ticket_detail, name="user-ticket-detail"),
    path("legal-agreements/", views.legal_agreements_page, name="user-legal-agreements"),
    path("trading-platform/", views.trading_platform_page, name="user-trading-platform"),
    path("profile/", views.profile_page, name="user-profile"),
    path("profile/change-password/", views.change_password_page, name="user-change-password"),
    path("profile/security/", views.security_center, name="user-security-center"),

    # Compatibility routes
    path("my-fund/deposit/", views.deposit_feature, name="user-feature-deposit"),
    path("my-fund/withdraw/", views.withdraw_feature, name="user-feature-withdraw"),
    path("my-fund/transfer/", views.internal_transfer_feature, name="user-transfer"),
    path("my-wallet/", views.wallet_page, name="user-my-wallet"),
    path("ib-programme/", views.ib_dashboard_page, name="user-ib-programme"),
    path("my-data/", views.deposit_report, name="user-my-data"),
    path("open-live-account/", views.open_live_account, name="user-open-live-account"),
    path("open-demo-account/", views.open_demo_account, name="user-open-demo-account"),
    path("open-demo-account/<str:login_id>/balance/", views.demo_balance_action, name="user-demo-balance-action"),
    path("accounts/<str:login_id>/metrics/", views.account_live_metrics, name="user-account-live-metrics"),
    path("accounts/<str:login_id>/information/", views.account_information_page, name="user-account-information"),
    path("accounts/<str:login_id>/statements/", views.account_statement_page, name="user-account-statements"),
    path("accounts/<str:login_id>/leverage/", views.account_leverage_page, name="user-account-leverage"),
    path("accounts/<str:login_id>/credential/<str:mode>/", views.account_credential_page, name="user-account-credential"),
    path("account-history/", views.account_history, name="user-account-history"),
    path("transaction-history/", views.transaction_history, name="user-transaction-history"),
    path("referral-link/", views.referral_link, name="user-referral-link"),
]

