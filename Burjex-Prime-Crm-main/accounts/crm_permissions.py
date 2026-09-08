"""
Granular CRM permission codes for RBAC. Admins/Bankers bypass checks.
Sales managers: user overrides → CRM role grants → department grants → defaults.
"""
from __future__ import annotations

from collections import defaultdict
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from accounts.models import User

# --- Permission codes (stable API for templates and views) ---

# Account
ACCOUNTS_VIEW = "accounts.view"
ACCOUNTS_CREATE = "accounts.create"
ACCOUNTS_EDIT = "accounts.edit"
ACCOUNTS_DELETE = "accounts.delete"

# KYC
KYC_VIEW = "kyc.view"
KYC_APPROVE = "kyc.approve"
KYC_REJECT = "kyc.reject"
KYC_UPLOAD = "kyc.upload_docs"
KYC_REQUEST_DOCS = "kyc.request_docs"
KYC_VIEW_DOCS = "kyc.view_docs"
KYC_EDIT = "kyc.edit"

# Finance
FINANCE_VIEW_DEPOSITS = "finance.view_deposits"
FINANCE_APPROVE_DEPOSITS = "finance.approve_deposits"
FINANCE_REJECT_DEPOSITS = "finance.reject_deposits"
FINANCE_WITHDRAWALS = "finance.withdrawals"
FINANCE_APPROVE_WITHDRAWALS = "finance.approve_withdrawals"
FINANCE_REJECT_WITHDRAWALS = "finance.reject_withdrawals"
FINANCE_WALLET = "finance.wallet"
FINANCE_VIEW_TRANSACTIONS = "finance.view_transactions"
FINANCE_EXPORT_TRANSACTIONS = "finance.export_transactions"

# Sales
SALES_VIEW_LEADS = "sales.view_leads"
SALES_ASSIGN_LEADS = "sales.assign_leads"
SALES_EDIT_LEADS = "sales.edit_leads"
SALES_CONVERT_LEADS = "sales.convert_leads"
SALES_VIEW_FUNNEL = "sales.view_funnel"
SALES_EDIT_FUNNEL = "sales.edit_funnel"
SALES_IB_ANALYTICS = "sales.ib_analytics"
SALES_TEAM_METRICS = "sales.team_metrics"
SALES_ACTIVITY = "sales.activity"
SALES_ASSIGN_CLIENTS = "sales.assign_clients"
SALES_UNASSIGN_CLIENTS = "sales.unassign_clients"
SALES_BULK_ASSIGN_CLIENTS = "sales.bulk_assign_clients"
SALES_VIEW_ANALYTICS = "sales.view_analytics"
SALES_EXPORT = "sales.export"
SALES_IMPORT = "sales.import_data"
SALES_VIEW_REVENUE_HUB = "sales.view_revenue_hub"

# Clients (CRM book operations)
CLIENT_VIEW_BALANCE = "clients.view_balance"
CLIENT_VIEW_EQUITY = "clients.view_equity"

PERMISSION_LABELS: dict[str, tuple[str, str]] = {
    ACCOUNTS_VIEW: ("Accounts", "View accounts"),
    ACCOUNTS_CREATE: ("Accounts", "Create accounts"),
    ACCOUNTS_EDIT: ("Accounts", "Edit accounts"),
    ACCOUNTS_DELETE: ("Accounts", "Delete accounts"),
    KYC_VIEW: ("KYC", "View KYC"),
    KYC_APPROVE: ("KYC", "Approve KYC"),
    KYC_REJECT: ("KYC", "Reject KYC"),
    KYC_UPLOAD: ("KYC", "Upload documents"),
    KYC_REQUEST_DOCS: ("KYC", "Request documents"),
    KYC_VIEW_DOCS: ("KYC", "View documents"),
    KYC_EDIT: ("KYC", "Edit KYC"),
    FINANCE_VIEW_DEPOSITS: ("Finance", "View deposits"),
    FINANCE_APPROVE_DEPOSITS: ("Finance", "Approve deposits"),
    FINANCE_REJECT_DEPOSITS: ("Finance", "Reject deposits"),
    FINANCE_WITHDRAWALS: ("Finance", "View withdrawals"),
    FINANCE_APPROVE_WITHDRAWALS: ("Finance", "Approve withdrawals"),
    FINANCE_REJECT_WITHDRAWALS: ("Finance", "Reject withdrawals"),
    FINANCE_WALLET: ("Finance", "Wallet access"),
    FINANCE_VIEW_TRANSACTIONS: ("Finance", "View transactions"),
    FINANCE_EXPORT_TRANSACTIONS: ("Finance", "Export transactions"),
    SALES_VIEW_LEADS: ("Sales", "View leads"),
    SALES_ASSIGN_LEADS: ("Sales", "Assign leads"),
    SALES_EDIT_LEADS: ("Sales", "Edit leads"),
    SALES_CONVERT_LEADS: ("Sales", "Convert leads"),
    SALES_VIEW_FUNNEL: ("Sales", "View funnel & clients"),
    SALES_EDIT_FUNNEL: ("Sales", "Edit funnel"),
    SALES_IB_ANALYTICS: ("Sales", "IB analytics"),
    SALES_TEAM_METRICS: ("Sales", "Team / performance metrics"),
    SALES_ACTIVITY: ("Sales", "Activity log"),
    SALES_ASSIGN_CLIENTS: ("Sales", "Assign clients to managers"),
    SALES_UNASSIGN_CLIENTS: ("Sales", "Unassign clients from managers"),
    SALES_BULK_ASSIGN_CLIENTS: ("Sales", "Bulk assign clients"),
    SALES_VIEW_ANALYTICS: ("Sales", "View analytics"),
    SALES_EXPORT: ("Sales", "Export reports"),
    SALES_IMPORT: ("Sales", "Import data"),
    SALES_VIEW_REVENUE_HUB: ("Sales", "Revenue hub"),
    CLIENT_VIEW_BALANCE: ("Clients", "View client balance"),
    CLIENT_VIEW_EQUITY: ("Clients", "View client equity"),
}

ALL_PERMISSION_CODES: tuple[str, ...] = tuple(PERMISSION_LABELS.keys())

# Folder order for permission UIs (matches user-facing groups).
PERMISSION_FOLDER_ORDER: tuple[str, ...] = (
    "KYC",
    "Finance",
    "Clients",
    "Sales",
    "Analytics",
    "Accounts",
)

# Shown under "Analytics" group in permission UIs (not duplicated under Sales).
_ANALYTICS_CODES = frozenset({SALES_VIEW_ANALYTICS, SALES_EXPORT, SALES_VIEW_REVENUE_HUB})


def permission_codes_grouped_by_folder() -> list[tuple[str, list[tuple[str, str]]]]:
    """[(folder_name, [(code, short_label), ...]), ...] for templates."""
    raw: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for code, (folder, label) in PERMISSION_LABELS.items():
        if code in _ANALYTICS_CODES:
            raw["Analytics"].append((code, label))
            continue
        raw[folder].append((code, label))
    out: list[tuple[str, list[tuple[str, str]]]] = []
    seen = set()
    for title in PERMISSION_FOLDER_ORDER:
        if title in raw:
            out.append((title, sorted(raw[title], key=lambda x: x[1])))
            seen.add(title)
    for title, items in sorted(raw.items()):
        if title not in seen:
            out.append((title, sorted(items, key=lambda x: x[1])))
    return out


# Default grants when user has no CRM role and no matching grant rows.
DEFAULT_SALES_MANAGER_PERMISSIONS: frozenset[str] = frozenset(
    {
        SALES_VIEW_LEADS,
        SALES_ASSIGN_LEADS,
        SALES_EDIT_LEADS,
        SALES_CONVERT_LEADS,
        SALES_VIEW_FUNNEL,
        SALES_ACTIVITY,
        CLIENT_VIEW_BALANCE,
        CLIENT_VIEW_EQUITY,
    }
)


def _effective_grant_for_code(user: User, code: str) -> bool | None:
    """
    None = fall through to defaults. User row beats role beats department.
    """
    from admin_panel.models import CrmPermissionGrant, CrmRoleGrant

    urow = (
        CrmPermissionGrant.objects.filter(user_id=user.pk, permission_code=code)
        .values_list("granted", flat=True)
        .first()
    )
    if urow is not None:
        return bool(urow)
    role_id = getattr(user, "crm_role_id", None)
    if role_id:
        rrow = (
            CrmRoleGrant.objects.filter(role_id=role_id, permission_code=code)
            .values_list("granted", flat=True)
            .first()
        )
        if rrow is not None:
            return bool(rrow)
    if user.crm_department_id:
        drow = (
            CrmPermissionGrant.objects.filter(
                department_id=user.crm_department_id,
                user__isnull=True,
                permission_code=code,
            )
            .values_list("granted", flat=True)
            .first()
        )
        if drow is not None:
            return bool(drow)
    return None


def user_has_crm_permission(user: User, code: str) -> bool:
    if not user.is_authenticated:
        return False
    if getattr(user, "is_superuser", False) or user.role in (user.Roles.ADMIN, user.Roles.BANKER):
        return True
    if user.role != user.Roles.SALES_MANAGER:
        return False
    resolved = _effective_grant_for_code(user, code)
    if resolved is not None:
        return resolved
    if getattr(user, "crm_role_id", None):
        return False
    return code in DEFAULT_SALES_MANAGER_PERMISSIONS
