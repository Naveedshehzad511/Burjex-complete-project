from django.urls import path

from api.views.admin_api import (
    AdminDashboardStatsAPIView,
    AdminPendingDepositsAPIView,
    AdminPendingWithdrawalsAPIView,
    AdminTransactionListAPIView,
    AdminUserDetailAPIView,
    AdminUserListAPIView,
)
from api.views.staff_portals import ManagerDashboardAPIView, SalesDashboardAPIView
from api.views.auth import (
    ChangePasswordAPIView,
    ClientLoginAPIView,
    ClientSignupAPIView,
    ClientTotpVerifyAPIView,
    ForgotPasswordAPIView,
    ResetPasswordAPIView,
    LogoutAPIView,
    ResendVerificationAPIView,
    StaffLoginAPIView,
    StaffTotpVerifyAPIView,
    VerifyEmailAPIView,
)
from api.views.social_auth import (
    AppleTokenAPIView,
    GoogleTokenAPIView,
    SocialOptionsAPIView,
    apple_callback,
    apple_start,
    google_callback,
    google_start,
)
from api.views.dashboard import ClientDashboardAPIView
from api.views.ib import (
    IBApplyAPIView,
    IBClientsAPIView,
    IBCommissionAPIView,
    IBDashboardAPIView,
    IBProgressAPIView,
)
from api.views.internal_transfer import InternalTransferAPIView
from api.views.kyc import KYCStatusAPIView, KYCUploadAPIView
from api.views.account_deletion import AccountDeletionAPIView
from api.views.me import MeAPIView, MeRestrictionsAPIView, SecurityTotpSetupAPIView
from api.views.notifications import ClientNotificationMarkReadAPIView, ClientNotificationsAPIView
from api.views.app_version import AppVersionAPIView
from api.views.branding import BrandingAPIView
from api.views.content import LegalAgreementsAPIView, TradingPlatformsAPIView
from api.views.portal_extra import (
    AccountCredentialAPIView,
    AccountHistoryAPIView,
    AccountLeverageAPIView,
    AccountStatementAPIView,
    AccountTradingSessionAPIView,
    DealReportAPIView,
    DemoBalanceAPIView,
    FilteredReportAPIView,
    IBTreeAPIView,
    IBWithdrawAPIView,
    MyDocumentsAPIView,
    SummaryReportAPIView,
    TeamReportAPIView,
)
from api.views.support import SupportTicketDetailAPIView, SupportTicketsAPIView
from api.views.trading_accounts import (
    AccountPositionsAPIView,
    OpenAccountAPIView,
    TradingAccountDetailAPIView,
    TradingAccountListAPIView,
    TradingAccountTypesAPIView,
)
from api.views.treasury import (
    DepositCreateAPIView,
    DepositCryptoAPIView,
    DepositMethodsAPIView,
    TransactionsListAPIView,
    WalletAPIView,
    WithdrawCreateAPIView,
    WithdrawMethodsAPIView,
)

app_name = "api"

urlpatterns = [
    # Auth
    path("auth/login/", ClientLoginAPIView.as_view(), name="client-login"),
    path("auth/social/options/", SocialOptionsAPIView.as_view(), name="social-options"),
    path("auth/google/", GoogleTokenAPIView.as_view(), name="auth-google"),
    path("auth/google/start/", google_start, name="auth-google-start"),
    path("auth/google/callback/", google_callback, name="auth-google-callback"),
    path("auth/apple/", AppleTokenAPIView.as_view(), name="auth-apple"),
    path("auth/apple/start/", apple_start, name="auth-apple-start"),
    path("auth/apple/callback/", apple_callback, name="auth-apple-callback"),
    path("auth/admin/login/", StaffLoginAPIView.as_view(), name="staff-login"),
    path("auth/totp/verify/", ClientTotpVerifyAPIView.as_view(), name="client-totp-verify"),
    path("auth/admin/totp/verify/", StaffTotpVerifyAPIView.as_view(), name="staff-totp-verify"),
    path("auth/signup/", ClientSignupAPIView.as_view(), name="client-signup"),
    path("auth/forgot-password/", ForgotPasswordAPIView.as_view(), name="forgot-password"),
    path("auth/reset-password/", ResetPasswordAPIView.as_view(), name="reset-password"),
    path("auth/verify-email/<str:token>/", VerifyEmailAPIView.as_view(), name="verify-email"),
    path("auth/verify-email/", VerifyEmailAPIView.as_view(), name="verify-email-post"),
    path("auth/resend-verification/", ResendVerificationAPIView.as_view(), name="resend-verification"),
    path("auth/logout/", LogoutAPIView.as_view(), name="logout"),
    path("auth/change-password/", ChangePasswordAPIView.as_view(), name="change-password"),
    # Profile / me
    path("me/", MeAPIView.as_view(), name="me"),
    path("me/restrictions/", MeRestrictionsAPIView.as_view(), name="me-restrictions"),
    path("me/security/totp/", SecurityTotpSetupAPIView.as_view(), name="me-totp"),
    path("me/deletion-request/", AccountDeletionAPIView.as_view(), name="me-deletion-request"),
    # Dashboard
    path("dashboard/", ClientDashboardAPIView.as_view(), name="dashboard"),
    # Wallet / treasury
    path("wallet/", WalletAPIView.as_view(), name="wallet"),
    path("deposits/methods/", DepositMethodsAPIView.as_view(), name="deposit-methods"),
    path("deposits/", DepositCreateAPIView.as_view(), name="deposit-create"),
    path("deposits/crypto/", DepositCryptoAPIView.as_view(), name="deposit-crypto"),
    path("withdrawals/methods/", WithdrawMethodsAPIView.as_view(), name="withdraw-methods"),
    path("withdrawals/", WithdrawCreateAPIView.as_view(), name="withdraw-create"),
    path("transactions/", TransactionsListAPIView.as_view(), name="transactions"),
    path("transfers/internal/", InternalTransferAPIView.as_view(), name="internal-transfer"),
    # Trading accounts
    path("accounts/", TradingAccountListAPIView.as_view(), name="accounts-list"),
    path("accounts/types/", TradingAccountTypesAPIView.as_view(), name="accounts-types"),
    path("accounts/open/", OpenAccountAPIView.as_view(), name="accounts-open"),
    path("accounts/positions/", AccountPositionsAPIView.as_view(), name="accounts-positions"),
    path("accounts/history/", AccountHistoryAPIView.as_view(), name="accounts-history"),
    path("accounts/<str:login_id>/leverage/", AccountLeverageAPIView.as_view(), name="accounts-leverage"),
    path(
        "accounts/<str:login_id>/trading-session/",
        AccountTradingSessionAPIView.as_view(),
        name="accounts-trading-session",
    ),
    path(
        "accounts/<str:login_id>/credential/<str:mode>/",
        AccountCredentialAPIView.as_view(),
        name="accounts-credential",
    ),
    path("accounts/<str:login_id>/demo-balance/", DemoBalanceAPIView.as_view(), name="accounts-demo-balance"),
    path("accounts/<str:login_id>/statements/", AccountStatementAPIView.as_view(), name="accounts-statements"),
    path("accounts/<str:account_id>/", TradingAccountDetailAPIView.as_view(), name="accounts-detail"),
    # KYC
    path("kyc/status/", KYCStatusAPIView.as_view(), name="kyc-status"),
    path("kyc/upload/", KYCUploadAPIView.as_view(), name="kyc-upload"),
    # IB
    path("ib/dashboard/", IBDashboardAPIView.as_view(), name="ib-dashboard"),
    path("ib/progress/", IBProgressAPIView.as_view(), name="ib-progress"),
    path("ib/apply/", IBApplyAPIView.as_view(), name="ib-apply"),
    path("ib/clients/", IBClientsAPIView.as_view(), name="ib-clients"),
    path("ib/commission/", IBCommissionAPIView.as_view(), name="ib-commission"),
    path("ib/tree/", IBTreeAPIView.as_view(), name="ib-tree"),
    path("ib/withdraw/", IBWithdrawAPIView.as_view(), name="ib-withdraw"),
    path("ib/team-report/<str:kind>/", TeamReportAPIView.as_view(), name="ib-team-report"),
    # My Data reports / documents
    path("reports/deals/", DealReportAPIView.as_view(), name="deal-report"),
    path("reports/summary/", SummaryReportAPIView.as_view(), name="summary-report"),
    path("reports/<str:kind>/", FilteredReportAPIView.as_view(), name="filtered-report"),
    path("documents/", MyDocumentsAPIView.as_view(), name="my-documents"),
    # Notifications
    path("notifications/", ClientNotificationsAPIView.as_view(), name="notifications"),
    path("notifications/<int:pk>/read/", ClientNotificationMarkReadAPIView.as_view(), name="notification-read"),
    # Support
    path("support/tickets/", SupportTicketsAPIView.as_view(), name="support-tickets"),
    path("support/tickets/<str:ticket_number>/", SupportTicketDetailAPIView.as_view(), name="support-ticket-detail"),
    # Content (admin-managed, client-visible)
    path("branding/", BrandingAPIView.as_view(), name="branding"),
    path("legal/", LegalAgreementsAPIView.as_view(), name="legal-agreements"),
    path("trading-platforms/", TradingPlatformsAPIView.as_view(), name="trading-platforms"),
    # Sideloaded-APK update signal (no store to announce releases for us).
    path("app-version/", AppVersionAPIView.as_view(), name="app-version"),
    # Admin
    path("admin/dashboard/stats/", AdminDashboardStatsAPIView.as_view(), name="admin-dashboard-stats"),
    path("admin/users/", AdminUserListAPIView.as_view(), name="admin-users"),
    path("admin/users/<int:pk>/", AdminUserDetailAPIView.as_view(), name="admin-user-detail"),
    path("admin/deposits/pending/", AdminPendingDepositsAPIView.as_view(), name="admin-pending-deposits"),
    path("admin/withdrawals/pending/", AdminPendingWithdrawalsAPIView.as_view(), name="admin-pending-withdrawals"),
    path("admin/transactions/", AdminTransactionListAPIView.as_view(), name="admin-transactions"),
    # Sales / Manager portals
    path("sales/dashboard/", SalesDashboardAPIView.as_view(), name="sales-dashboard"),
    path("manager/dashboard/", ManagerDashboardAPIView.as_view(), name="manager-dashboard"),
]
