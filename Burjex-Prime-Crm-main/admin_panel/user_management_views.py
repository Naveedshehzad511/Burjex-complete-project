import re
import secrets
import csv
from decimal import Decimal

from django.conf import settings
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db import transaction as db_transaction
from django.db.models import Exists, OuterRef, Q, Sum
from django.http import HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.core.paginator import Paginator
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.models import (
    BankDetails,
    Document,
    MAX_VERIFIED_BANK_ACCOUNTS_PER_USER,
    MAX_VERIFIED_CRYPTO_WALLETS_PER_USER,
    MT5Account,
    MT5Group,
    User,
    VerifiedBankAccount,
    VerifiedCryptoAddress,
)
from accounts.permissions import role_required
from enterprise.audit import get_client_ip, log_audit
from enterprise.models import AuditLogChannel
from enterprise.upload_security import validate_document_upload
from accounts.restrictions import get_or_create_restriction
from ib.models import IBLevel, IBProfile
from ib.referral import ensure_profile_referral_url, generate_unique_ib_code
from transactions.models import BalanceLedger, InternalTransfer, Transaction

from admin_panel.models import CryptoNetwork, StatusBadgeSettings, Tag, UserActivitySettings, UserTag
from admin_panel.templated_mail import send_event_email
from admin_panel.um_badge_utils import default_badge_data, merge_badge_data
from admin_panel.views import _parse_list_status, _querystring_excluding

from .services.kyc import KYC_QUEUE_DOCUMENT_TYPES, get_kyc_queue_status_counts, recalc_user_kyc

KYC_DOC_TYPES = KYC_QUEUE_DOCUMENT_TYPES

LEVERAGE_CHOICES = [50, 100, 200, 300, 500, 1000, 2000, 0]  # 0 => Unlimited

RESTRICTION_BOOL_FIELDS = (
    "disable_deposit",
    "disable_withdraw",
    "disable_transfer",
    "disable_internal_transfer",
    "disable_wallet_to_mt5",
    "disable_mt5_to_wallet",
    "disable_ib_withdraw",
    "disable_trading",
    "disable_create_mt5",
    "disable_profile_access",
    "disable_client_area",
)


def _badge_cells_for_user(u: User, bd: dict) -> dict:
    """Build badge style dicts for one user row."""
    eb = bd["email_verified"] if u.email_verified else bd["email_unverified"]
    if u.kyc_status == User.KYCStatus.APPROVED:
        kb = bd["kyc_verified"]
    elif u.kyc_status == User.KYCStatus.PENDING:
        kb = bd["kyc_pending"]
    elif u.kyc_status == User.KYCStatus.EXPIRED:
        kb = bd["kyc_expired"]
    else:
        kb = bd["kyc_rejected"]
    if not u.is_active or u.account_status in (User.AccountStatus.BLOCKED, User.AccountStatus.SUSPENDED):
        ab = bd["acct_disabled"]
    elif u.account_status == User.AccountStatus.PENDING:
        ab = bd["acct_pending"]
    else:
        ab = bd["acct_active"]
    return {"email": eb, "kyc": kb, "account": ab}


def _mt5_server() -> str:
    return getattr(settings, "MT5_DEFAULT_SERVER", "Broker-MT5")


def _client_users_qs():
    return User.objects.filter(
        role__in=[
            User.Roles.CLIENT,
            User.Roles.TRADER,
            User.Roles.COPIER,
            User.Roles.IB,
        ]
    ).order_by("email")


def _crm_user_list_qs():
    return User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]).order_by("-date_joined")


def _live_mt5_min_balance_exists(min_bal: Decimal):
    return MT5Account.objects.filter(
        user_id=OuterRef("pk"),
        account_type=MT5Account.AccountType.LIVE,
        balance__gte=min_bal,
    )


def _user_list_active_qs(base_qs, active_since, min_bal: Decimal):
    """Active = last login within window AND at least one live MT5 with balance >= min_bal."""
    return base_qs.filter(last_login__isnull=False, last_login__gte=active_since).filter(
        Exists(_live_mt5_min_balance_exists(min_bal))
    )


def _wallet_balances(user_ids: list[int]) -> dict[int, float]:
    if not user_ids:
        return {}
    dep_types = [Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT]
    wdr_types = [Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW]
    ok = [Transaction.Status.APPROVED, Transaction.Status.COMPLETED]
    deposits = (
        Transaction.objects.filter(actor_id__in=user_ids, tx_type__in=dep_types, status__in=ok)
        .values("actor_id")
        .annotate(total=Sum("amount"))
    )
    withdrawals = (
        Transaction.objects.filter(actor_id__in=user_ids, tx_type__in=wdr_types, status__in=ok)
        .values("actor_id")
        .annotate(total=Sum("amount"))
    )
    dmap = {r["actor_id"]: r["total"] or 0 for r in deposits}
    wmap = {r["actor_id"]: r["total"] or 0 for r in withdrawals}
    return {uid: float(dmap.get(uid, 0) - wmap.get(uid, 0)) for uid in user_ids}


def _unique_username_from_email(email: str) -> str:
    local = (email.split("@")[0] if "@" in email else email) or "user"
    base = re.sub(r"[^a-zA-Z0-9_]", "_", local)[:30] or "user"
    candidate = base
    n = 0
    while User.objects.filter(username=candidate).exists():
        n += 1
        candidate = f"{base}_{n}"[:150]
    return candidate


def _gen_mt5_login() -> str:
    for _ in range(30):
        lid = str(secrets.randbelow(10**10)).zfill(10)
        if not MT5Account.objects.filter(login_id=lid).exists():
            return lid
    return secrets.token_hex(8)


def _safe_email(subject: str, body: str, to_email: str) -> None:
    if not to_email:
        return
    try:
        from admin_panel.email_service import send_dynamic_email

        send_dynamic_email(to_email, subject, body)
    except Exception:
        pass


def _doc_event_key(doc_type: str, approved: bool) -> str:
    dt = (doc_type or "").upper()
    if dt in {
        Document.DocType.PASSPORT,
        Document.DocType.NATIONAL_ID,
        Document.DocType.ID_DOCUMENT_FRONT,
        Document.DocType.ID_DOCUMENT_BACK,
        Document.DocType.SELFIE,
    }:
        return "identity_approved" if approved else "identity_rejected"
    if dt in {Document.DocType.PROOF_OF_ADDRESS, Document.DocType.UTILITY_BILL}:
        return "address_approved" if approved else "address_rejected"
    return "kyc_approved" if approved else "kyc_rejected"


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_add_user(request):
    if request.method == "POST":
        return_to_list = (request.POST.get("return_to_list") or "").strip() == "1"
        name = (request.POST.get("name") or "").strip()
        country = (request.POST.get("country") or "").strip()
        email = (request.POST.get("email") or "").strip().lower()
        phone = (request.POST.get("phone") or "").strip()
        password = request.POST.get("password") or ""

        if not all([name, country, email, phone, password]):
            messages.error(request, "All fields are required.")
        elif User.objects.filter(email__iexact=email).exists():
            messages.error(request, "A user with this email already exists.")
        else:
            username = _unique_username_from_email(email)
            user = User.objects.create_user(
                username=username,
                email=email,
                password=password,
                first_name=name[:150],
                role=User.Roles.CLIENT,
                phone=phone,
                country=country,
            )
            try:
                from django.urls import reverse

                from enterprise.staff_notify import broadcast_staff_notification

                broadcast_staff_notification(
                    "New client added",
                    f"Admin created client {user.display_name()} ({user.email}).",
                    action_url=reverse("admin-user-list"),
                )
            except Exception:
                pass
            messages.success(request, f"User created: {user.email}")
            return redirect("admin-user-list")
        if return_to_list:
            return redirect("admin-user-list")

    return render(request, "admin_panel/user_management/add_user.html", {"title": "Add User"})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_user_list(request):
    q = (request.GET.get("q") or "").strip()
    name_q = (request.GET.get("name") or "").strip()
    email_q = (request.GET.get("email") or "").strip()
    country_q = (request.GET.get("country") or "").strip()
    ib_q = (request.GET.get("ib") or "").strip()
    wallet_min = (request.GET.get("wallet_min") or "").strip()
    wallet_max = (request.GET.get("wallet_max") or "").strip()
    email_status = (request.GET.get("email_status") or "").strip().lower()
    kyc_status = (request.GET.get("kyc_status") or "").strip().upper()
    status = (request.GET.get("status") or "").strip().upper()
    active_state = (request.GET.get("active_state") or "").strip().lower()
    date_from = (request.GET.get("date_from") or "").strip()
    date_to = (request.GET.get("date_to") or "").strip()
    last_login_from = (request.GET.get("last_login_from") or "").strip()
    last_login_to = (request.GET.get("last_login_to") or "").strip()
    today_only = (request.GET.get("today") or "").strip() in {"1", "true", "on"}
    card = (request.GET.get("card") or "").strip().lower()
    sort = (request.GET.get("sort") or "-date_joined").strip()
    export = (request.GET.get("export") or "").strip().lower()
    per_page = (request.GET.get("per_page") or "25").strip()
    role_f = (request.GET.get("role") or "").strip().upper()
    account_status_f = (request.GET.get("account_status") or "").strip().upper()
    tag_id_f = (request.GET.get("tag_id") or "").strip()
    try:
        per_page_i = int(per_page)
    except ValueError:
        per_page_i = 25
    if per_page_i not in {10, 25, 50, 100}:
        per_page_i = 25
    list_scope = (request.GET.get("list_scope") or "crm").strip().lower()
    engagement = (request.GET.get("engagement") or "").strip().lower()
    if list_scope == "all":
        users_qs = User.objects.all().select_related("referred_by")
    else:
        users_qs = _crm_user_list_qs().select_related("referred_by")
    settings_obj = UserActivitySettings.get_solo()
    active_days = settings_obj.effective_active_days()
    min_bal = settings_obj.effective_min_balance()
    active_since = timezone.now() - timezone.timedelta(days=active_days)

    role_allowed = {User.Roles.CLIENT, User.Roles.IB, User.Roles.TRADER, User.Roles.COPIER}
    if role_f in role_allowed:
        users_qs = users_qs.filter(role=role_f)
    acct_choices = {c for c, _ in User.AccountStatus.choices}
    if account_status_f in acct_choices:
        users_qs = users_qs.filter(account_status=account_status_f)
    if tag_id_f.isdigit():
        users_qs = users_qs.filter(user_tags__tag_id=int(tag_id_f)).distinct()
    if q:
        users_qs = users_qs.filter(
            Q(first_name__icontains=q)
            | Q(last_name__icontains=q)
            | Q(email__icontains=q)
            | Q(phone__icontains=q)
            | Q(country__icontains=q)
        )
    if name_q:
        users_qs = users_qs.filter(Q(first_name__icontains=name_q) | Q(last_name__icontains=name_q))
    if email_q:
        users_qs = users_qs.filter(email__icontains=email_q)
    if country_q:
        users_qs = users_qs.filter(country__icontains=country_q)
    if ib_q:
        users_qs = users_qs.filter(
            Q(referred_by__first_name__icontains=ib_q)
            | Q(referred_by__last_name__icontains=ib_q)
            | Q(referred_by__email__icontains=ib_q)
        )
    if email_status == "verified":
        users_qs = users_qs.filter(email_verified=True)
    elif email_status == "unverified":
        users_qs = users_qs.filter(email_verified=False)
    if kyc_status in {User.KYCStatus.PENDING, User.KYCStatus.APPROVED, User.KYCStatus.EXPIRED}:
        users_qs = users_qs.filter(kyc_status=kyc_status)
    if status == "ACTIVE":
        users_qs = users_qs.filter(is_active=True)
    elif status == "PENDING":
        users_qs = users_qs.filter(kyc_status=User.KYCStatus.PENDING)
    elif status == "REJECTED":
        users_qs = users_qs.filter(kyc_status=User.KYCStatus.EXPIRED)
    elif status == "VERIFIED":
        users_qs = users_qs.filter(kyc_status=User.KYCStatus.APPROVED)
    if active_state == "active":
        users_qs = _user_list_active_qs(users_qs, active_since, min_bal)
    elif active_state == "inactive":
        active_pks = _user_list_active_qs(_crm_user_list_qs(), active_since, min_bal).values("pk")
        users_qs = users_qs.exclude(pk__in=active_pks)
    if card == "active":
        users_qs = _user_list_active_qs(users_qs, active_since, min_bal)
    elif card == "inactive":
        active_pks = _user_list_active_qs(_crm_user_list_qs(), active_since, min_bal).values("pk")
        users_qs = users_qs.exclude(pk__in=active_pks)
    elif card == "today":
        users_qs = users_qs.filter(date_joined__date=timezone.localdate())
    if today_only:
        users_qs = users_qs.filter(date_joined__date=timezone.localdate())
    if date_from:
        users_qs = users_qs.filter(date_joined__date__gte=date_from)
    if date_to:
        users_qs = users_qs.filter(date_joined__date__lte=date_to)
    if last_login_from:
        users_qs = users_qs.filter(last_login__date__gte=last_login_from)
    if last_login_to:
        users_qs = users_qs.filter(last_login__date__lte=last_login_to)
    if engagement == "active_30d":
        cutoff_login = timezone.now() - timezone.timedelta(days=30)
        users_qs = users_qs.filter(last_login__isnull=False, last_login__gte=cutoff_login)
    elif engagement == "inactive_30d":
        cutoff_login = timezone.now() - timezone.timedelta(days=30)
        users_qs = users_qs.filter(Q(last_login__isnull=True) | Q(last_login__lt=cutoff_login))
    try:
        if wallet_min:
            users_qs = users_qs.filter(wallet_balance__gte=Decimal(wallet_min))
        if wallet_max:
            users_qs = users_qs.filter(wallet_balance__lte=Decimal(wallet_max))
    except Exception:
        pass

    allowed_sort = {"id", "-id", "first_name", "-first_name", "email", "-email", "country", "-country", "date_joined", "-date_joined", "last_login", "-last_login"}
    if sort not in allowed_sort:
        sort = "-date_joined"
    users_qs = users_qs.order_by(sort).distinct()

    if export == "excel":
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = 'attachment; filename="user_list.csv"'
        writer = csv.writer(response)
        writer.writerow(["ID", "Name", "Email", "Country", "Wallet", "Email Verified", "KYC", "Account", "Last Login", "Registered"])
        for u in users_qs[:5000]:
            writer.writerow(
                [
                    u.id,
                    u.display_name(),
                    u.email,
                    u.country or "",
                    float(u.wallet_balance or 0),
                    "Yes" if u.email_verified else "No",
                    u.kyc_status,
                    u.account_status,
                    timezone.localtime(u.last_login).strftime("%Y-%m-%d %H:%M") if u.last_login else "",
                    timezone.localtime(u.date_joined).strftime("%Y-%m-%d %H:%M"),
                ]
            )
        return response

    total_qs = _crm_user_list_qs()
    total_users_count = total_qs.count()
    active_users_count = _user_list_active_qs(total_qs, active_since, min_bal).count()
    inactive_users_count = total_qs.exclude(
        pk__in=_user_list_active_qs(total_qs, active_since, min_bal).values("pk")
    ).count()
    today_users_count = total_qs.filter(date_joined__date=timezone.localdate()).count()

    paginator = Paginator(users_qs, per_page_i)
    page_obj = paginator.get_page(request.GET.get("page"))
    users = list(page_obj.object_list.prefetch_related("user_tags__tag", "user_tags__tag__category"))
    ids = [u.id for u in users]
    wallets = _wallet_balances(ids)
    badge_data = merge_badge_data(StatusBadgeSettings.get_solo().data)
    rows = []
    for u in users:
        rows.append(
            {
                "user": u,
                "wallet": wallets.get(u.id, 0),
                "ib_name": u.referred_by.display_name() if u.referred_by_id else "—",
                "badges": _badge_cells_for_user(u, badge_data),
                "is_ib": u.role == User.Roles.IB,
                "tags": [ut for ut in u.user_tags.all() if ut.tag and ut.tag.is_active],
            }
        )
    available_tags = Tag.objects.filter(is_active=True).select_related("category").order_by("category__name", "name")[:500]
    return render(
        request,
        "admin_panel/user_management/user_list.html",
        {
            "title": "User List",
            "rows": rows,
            "page_obj": page_obj,
            "filters": {
                "q": q,
                "name": name_q,
                "email": email_q,
                "country": country_q,
                "ib": ib_q,
                "wallet_min": wallet_min,
                "wallet_max": wallet_max,
                "email_status": email_status,
                "kyc_status": kyc_status,
                "status": status,
                "active_state": active_state,
                "date_from": date_from,
                "date_to": date_to,
                "today": today_only,
                "last_login_from": last_login_from,
                "last_login_to": last_login_to,
                "card": card,
                "sort": sort,
                "per_page": per_page_i,
                "role": role_f,
                "account_status": account_status_f,
                "tag_id": tag_id_f,
                "list_scope": list_scope,
                "engagement": engagement,
            },
            "badge_data": badge_data,
            "available_tags": available_tags,
            "stats": {
                "total_users": total_users_count,
                "active_users": active_users_count,
                "inactive_users": inactive_users_count,
                "today_users": today_users_count,
                "active_days": active_days,
            },
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def um_user_block_toggle(request, pk: int):
    user = get_object_or_404(_crm_user_list_qs(), pk=pk)
    user.is_active = not user.is_active
    user.save(update_fields=["is_active"])
    messages.success(request, f"User {'unblocked' if user.is_active else 'blocked'}: {user.email}")
    return redirect("admin-user-list")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_account_approval(request):
    if request.method == "POST":
        uid = request.POST.get("user_id")
        action = request.POST.get("action")
        user = User.objects.filter(id=uid).exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]).first()
        if not user:
            messages.error(request, "User not found.")
            return redirect("admin-account-approval")
        if action == "approve":
            user.is_active = True
            user.email_verified = True
            user.save(update_fields=["is_active", "email_verified"])
            messages.success(request, f"Approved account: {user.email}")
        elif action == "reject":
            user.is_active = False
            user.save(update_fields=["is_active"])
            messages.success(request, f"Rejected account: {user.email}")
        return redirect("admin-account-approval")

    rows = User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]).order_by("-date_joined")[:500]
    return render(request, "admin_panel/user_management/account_approval.html", {"title": "Account Approval", "rows": rows})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_user_activity(request):
    uid = request.GET.get("user_id") or ""
    users = _crm_user_list_qs()[:500]
    selected = User.objects.filter(id=uid).first() if uid else None
    tx_qs = Transaction.objects.select_related("actor", "payment_gateway").order_by("-created_at")
    docs_qs = Document.objects.select_related("user").order_by("-uploaded_at")
    if selected:
        tx_qs = tx_qs.filter(actor=selected)
        docs_qs = docs_qs.filter(user=selected)
    return render(
        request,
        "admin_panel/user_management/user_activity.html",
        {"title": "User Activity", "users": users, "selected": selected, "transactions": tx_qs[:150], "documents": docs_qs[:150]},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_user_view(request, pk: int):
    user = get_object_or_404(_crm_user_list_qs().select_related("referred_by", "ib_linked_by"), pk=pk)
    wallet = _wallet_balances([user.id]).get(user.id, 0)
    mt5_accounts = list(MT5Account.objects.filter(user=user).select_related("group").order_by("-created_at")[:50])
    ib_profile = IBProfile.objects.filter(user=user).first()
    referred = user.referred_by
    deposits = list(
        Transaction.objects.filter(actor=user, tx_type__in=[Transaction.TxType.CLIENT_DEPOSIT, Transaction.TxType.WALLET_DEPOSIT])
        .select_related("payment_gateway")
        .order_by("-created_at")[:40]
    )
    withdraws = list(
        Transaction.objects.filter(actor=user, tx_type__in=[Transaction.TxType.CLIENT_WITHDRAW, Transaction.TxType.WALLET_WITHDRAW])
        .select_related("payment_gateway")
        .order_by("-created_at")[:40]
    )
    verified_banks = list(VerifiedBankAccount.objects.filter(user=user).order_by("-created_at")[:20])
    verified_cryptos = list(VerifiedCryptoAddress.objects.filter(user=user).order_by("-created_at")[:20])
    bank_n = VerifiedBankAccount.objects.filter(user=user).count()
    crypto_n = VerifiedCryptoAddress.objects.filter(user=user).count()
    crypto_network_options = list(CryptoNetwork.objects.filter(is_enabled=True).order_by("label"))
    transfers = list(InternalTransfer.objects.filter(user=user).order_by("-created_at")[:40])
    documents = list(Document.objects.filter(user=user).order_by("-uploaded_at")[:30])
    ib_list = list(User.objects.filter(role=User.Roles.IB).order_by("email")[:500])
    restriction = get_or_create_restriction(user)
    badge_data = merge_badge_data(StatusBadgeSettings.get_solo().data)
    badges = _badge_cells_for_user(user, badge_data)
    user_tags = list(UserTag.objects.filter(user=user).select_related("tag", "tag__category", "assigned_by").order_by("-assigned_at"))
    assignable_tags = list(Tag.objects.filter(is_active=True).select_related("category").order_by("category__name", "name"))
    total_dep = sum(float(t.amount or 0) for t in deposits if t.status in (Transaction.Status.APPROVED, Transaction.Status.COMPLETED))
    total_wdr = sum(float(t.amount or 0) for t in withdraws if t.status in (Transaction.Status.APPROVED, Transaction.Status.COMPLETED))
    return render(
        request,
        "admin_panel/user_management/user_detail.html",
        {
            "title": "View User",
            "u": user,
            "wallet": wallet,
            "wallet_live": float(user.wallet_balance or 0),
            "ib_name": referred.display_name() if referred else "—",
            "mt5_accounts": mt5_accounts,
            "ib_profile": ib_profile,
            "deposits": deposits,
            "withdraws": withdraws,
            "verified_banks": verified_banks,
            "verified_cryptos": verified_cryptos,
            "bank_slots_left": max(0, MAX_VERIFIED_BANK_ACCOUNTS_PER_USER - bank_n),
            "crypto_slots_left": max(0, MAX_VERIFIED_CRYPTO_WALLETS_PER_USER - crypto_n),
            "max_verified_banks": MAX_VERIFIED_BANK_ACCOUNTS_PER_USER,
            "max_verified_crypto": MAX_VERIFIED_CRYPTO_WALLETS_PER_USER,
            "crypto_network_options": crypto_network_options,
            "transfers": transfers,
            "documents": documents,
            "ib_list": ib_list,
            "restriction": restriction,
            "badges": badges,
            "groups": MT5Group.objects.order_by("name"),
            "leverages": LEVERAGE_CHOICES,
            "total_dep": total_dep,
            "total_wdr": total_wdr,
            "user_tags": user_tags,
            "assignable_tags": assignable_tags,
            "all_ib_levels": IBLevel.objects.filter(is_active=True).order_by("sequence", "id"),
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_user_edit(request, pk: int):
    user = get_object_or_404(_crm_user_list_qs(), pk=pk)
    ib_users = User.objects.filter(role=User.Roles.IB).order_by("email")
    groups = MT5Group.objects.order_by("name")
    ib_profile = IBProfile.objects.filter(user=user).first()
    if request.method == "POST":
        old_role = user.role
        name = (request.POST.get("name") or "").strip()
        last_name = (request.POST.get("last_name") or "").strip()
        country = (request.POST.get("country") or "").strip()
        email = (request.POST.get("email") or "").strip().lower()
        phone = (request.POST.get("phone") or "").strip()
        marketing_name = (request.POST.get("marketing_name") or "").strip()
        email_verified = request.POST.get("email_verified") == "on"
        phone_verified = request.POST.get("phone_verified") == "on"
        kyc_verified_toggle = request.POST.get("kyc_verified") == "on"
        role = (request.POST.get("role") or user.role).strip().upper()

        account_status = (request.POST.get("account_status") or user.account_status).strip().upper()
        ib_user_id = request.POST.get("ib_user_id") or ""
        mt5_group_id = request.POST.get("mt5_group_id") or ""
        if not all([name, country, email, phone]):
            messages.error(request, "Name, country, email, and phone are required.")
        elif User.objects.filter(email__iexact=email).exclude(pk=user.pk).exists():
            messages.error(request, "Another user already uses this email.")
        elif role not in {User.Roles.CLIENT, User.Roles.TRADER, User.Roles.IB, User.Roles.COPIER}:
            messages.error(request, "Invalid role for this form.")
        elif account_status not in {s for s, _ in User.AccountStatus.choices}:
            messages.error(request, "Invalid account status.")
        else:
            old_ib = user.referred_by_id
            user.first_name = name[:150]
            user.last_name = last_name[:150]
            user.country = country
            user.email = email
            user.phone = phone
            user.marketing_name = marketing_name[:120]
            user.email_verified = email_verified
            user.phone_verified = phone_verified
            user.role = role
            user.account_status = account_status
            if kyc_verified_toggle:
                user.kyc_status = User.KYCStatus.APPROVED
            new_ib = User.objects.filter(id=ib_user_id, role=User.Roles.IB).first() if ib_user_id else None
            user.referred_by = new_ib
            if (old_ib or None) != (new_ib.id if new_ib else None):
                user.ib_linked_at = timezone.now() if new_ib else None
                user.ib_linked_by = request.user if new_ib else None
            user.save()
            if role == User.Roles.IB:
                seed = generate_unique_ib_code()
                prof, _ = IBProfile.objects.get_or_create(
                    user=user,
                    defaults={
                        "ib_code": seed,
                        "referral_link": "",
                    },
                )
                ensure_profile_referral_url(request, prof)
                prof.save(update_fields=["ib_code", "referral_link"])
            if mt5_group_id:
                group = MT5Group.objects.filter(id=mt5_group_id).first()
                if group:
                    MT5Account.objects.filter(user=user).update(group=group)
            if old_role != user.role:
                log_audit(
                    action="CLIENT_ROLE_CHANGE",
                    entity_type="User",
                    entity_id=str(user.id),
                    actor=request.user,
                    channel=AuditLogChannel.ADMIN,
                    request=request,
                    ip=get_client_ip(request),
                    metadata={"from": old_role, "to": user.role},
                )
            messages.success(request, "User updated successfully.")
            return redirect("admin-user-list")
    return render(
        request,
        "admin_panel/user_management/user_edit.html",
        {
            "title": "Edit User",
            "u": user,
            "ib_users": ib_users,
            "groups": groups,
            "ib_profile": ib_profile,
            "role_choices": [User.Roles.CLIENT, User.Roles.TRADER, User.Roles.IB, User.Roles.COPIER],

            "account_status_choices": User.AccountStatus.choices,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def um_user_delete(request, pk: int):
    user = get_object_or_404(_crm_user_list_qs(), pk=pk)
    if user.is_superuser:
        messages.error(request, "Cannot delete a superuser.")
        return redirect("admin-user-list")
    user.delete()
    messages.success(request, "User deleted.")
    return redirect("admin-user-list")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def um_promote_ib(request, pk: int):
    user = get_object_or_404(_crm_user_list_qs(), pk=pk)
    if user.role == User.Roles.IB:
        messages.info(request, "User is already an IB.")
        return redirect("admin-user-list")
    user.role = User.Roles.IB
    user.save(update_fields=["role"])
    seed = generate_unique_ib_code()
    prof, _ = IBProfile.objects.get_or_create(
        user=user,
        defaults={"ib_code": seed, "referral_link": ""},
    )
    ensure_profile_referral_url(request, prof)
    prof.save(update_fields=["ib_code", "referral_link"])
    messages.success(request, f"Promoted to IB: {user.email}")
    return redirect("admin-user-list")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def um_user_quick_action(request, pk: int):
    user = get_object_or_404(_crm_user_list_qs(), pk=pk)
    back = reverse("admin-user-view", args=[pk])
    action = (request.POST.get("action") or "").strip()

    if action == "wallet_deposit":
        destination = request.POST.get("destination") or "wallet"
        comment = (request.POST.get("comment") or "Admin wallet deposit").strip()
        try:
            amt = Decimal(str(request.POST.get("amount") or "0"))
        except Exception:
            amt = Decimal("0")
        
        if amt <= 0:
            messages.error(request, "Enter a valid deposit amount.")
        else:
            if destination == "wallet":
                with db_transaction.atomic():
                    u = User.objects.select_for_update().get(pk=user.pk)
                    wb = Decimal(str(u.wallet_balance or 0))
                    u.wallet_balance = wb + amt
                    u.save(update_fields=["wallet_balance"])
                    Transaction.objects.create(
                        actor=u,
                        tx_type=Transaction.TxType.WALLET_DEPOSIT,
                        status=Transaction.Status.APPROVED,
                        amount=amt,
                        currency=(request.POST.get("currency") or "USD")[:10],
                        notes=comment,
                    )
                    BalanceLedger.objects.create(
                        user=u,
                        entry_type=BalanceLedger.EntryType.TRANSFER_CREDIT,
                        amount=amt,
                        currency=(request.POST.get("currency") or "USD")[:10],
                        wallet_before=wb,
                        wallet_after=u.wallet_balance,
                        pending_before=Decimal(str(u.pending_withdraw or 0)),
                        pending_after=Decimal(str(u.pending_withdraw or 0)),
                        note=comment,
                    )
                messages.success(request, "Wallet credited.")
            elif destination.startswith("mt5_"):
                try:
                    mt5_login = int(destination.split("_")[1])
                    from mt5_integration.services import mt5_balance_deposit
                    mt5_balance_deposit(mt5_login, float(amt), comment)
                    messages.success(request, f"MT5 account {mt5_login} credited.")
                except Exception as e:
                    messages.error(request, f"MT5 deposit failed: {e}")

    elif action == "wallet_withdraw":
        source = request.POST.get("source") or "wallet"
        comment = (request.POST.get("comment") or "Admin wallet withdrawal").strip()
        try:
            amt = Decimal(str(request.POST.get("amount") or "0"))
        except Exception:
            amt = Decimal("0")
            
        if source == "wallet":
            with db_transaction.atomic():
                u = User.objects.select_for_update().get(pk=user.pk)
                wb = Decimal(str(u.wallet_balance or 0))
                pw = Decimal(str(u.pending_withdraw or 0))
                available = wb - pw
                if amt <= 0 or amt > available:
                    messages.error(
                        request,
                        f"Invalid amount or insufficient available wallet balance "
                        f"(wallet {wb}, pending withdraw hold {pw}, available {available}).",
                    )
                else:
                    u.wallet_balance = wb - amt
                    u.save(update_fields=["wallet_balance"])
                    Transaction.objects.create(
                        actor=u,
                        tx_type=Transaction.TxType.WALLET_WITHDRAW,
                        status=Transaction.Status.APPROVED,
                        amount=amt,
                        currency=(request.POST.get("currency") or "USD")[:10],
                        notes=comment,
                    )
                    BalanceLedger.objects.create(
                        user=u,
                        entry_type=BalanceLedger.EntryType.TRANSFER_DEBIT,
                        amount=amt,
                        currency=(request.POST.get("currency") or "USD")[:10],
                        wallet_before=wb,
                        wallet_after=u.wallet_balance,
                        pending_before=pw,
                        pending_after=pw,
                        note=comment,
                    )
                    messages.success(request, "Wallet debited.")
        elif source.startswith("mt5_"):
            if amt <= 0:
                messages.error(request, "Invalid amount.")
            else:
                try:
                    login_raw = source.split("_", 1)[1]
                    from admin_panel.models import TradingAccount
                    from btrader_integration.services import (
                        is_btrader_account_row,
                        validate_trading_debit_amount,
                        withdraw_btrader_balance,
                    )

                    ta = (
                        TradingAccount.objects.select_related("mt5_account", "mt5_account__group")
                        .filter(mt5_account__login_id=str(login_raw))
                        .first()
                    )
                    if ta:
                        guard = validate_trading_debit_amount(ta, amt)
                        if guard:
                            messages.error(request, guard)
                        elif is_btrader_account_row(trading_account=ta):
                            withdraw_btrader_balance(
                                login=str(login_raw),
                                amount=float(amt),
                                comment=comment,
                                external_ref=f"crm-admin-wd-{user.pk}-{login_raw}-{timezone.now().timestamp()}",
                            )
                            messages.success(request, f"BTrader account {login_raw} debited.")
                        else:
                            from mt5_integration.services import mt5_balance_withdrawal

                            mt5_balance_withdrawal(int(login_raw), float(amt), comment)
                            messages.success(request, f"MT5 account {login_raw} debited.")
                    else:
                        from mt5_integration.services import mt5_balance_withdrawal

                        mt5_balance_withdrawal(int(login_raw), float(amt), comment)
                        messages.success(request, f"MT5 account {login_raw} debited.")
                except Exception as e:
                    messages.error(request, f"Trading account withdrawal failed: {e}")

    elif action == "create_mt5":
        gid = request.POST.get("group_id") or ""
        lev_raw = request.POST.get("leverage") or "100"
        pwd = request.POST.get("mt5_password") or ""
        group = MT5Group.objects.filter(id=gid).first()
        try:
            leverage = int(lev_raw)
        except ValueError:
            leverage = 100
        if not group:
            messages.error(request, "Select a valid MT5 group.")
        elif leverage not in LEVERAGE_CHOICES:
            messages.error(request, "Invalid leverage.")
        else:
            acc = MT5Account.objects.create(
                user=user,
                account_type=MT5Account.AccountType.LIVE,
                login_id=_gen_mt5_login(),
                server=_mt5_server(),
                group=group,
                leverage=leverage,
                status=MT5Account.Status.ACTIVE,
            )
            if pwd:
                acc.set_mt5_password(pwd)
                acc.save(update_fields=["mt5_password_encrypted", "updated_at"])
            messages.success(request, f"MT5 account created: {acc.login_id}")

    elif action == "bank_add":
        account_name = (request.POST.get("account_holder_name") or "").strip()
        account_no = (request.POST.get("account_number") or "").strip()
        bank_name = (request.POST.get("bank_name") or "").strip()
        iban = (request.POST.get("iban") or "").strip()
        swift = (request.POST.get("swift_code") or "").strip()
        country = (request.POST.get("country") or "").strip()
        bank_address = (request.POST.get("bank_address") or "").strip()
        auto_verify = request.POST.get("auto_verify") == "on"
        if not account_name or not bank_name or not country:
            messages.error(request, "Account holder name, bank name, and country are required.")
        elif not account_no and not iban:
            messages.error(request, "Provide either an account number or an IBAN.")
        elif VerifiedBankAccount.objects.filter(user=user).count() >= MAX_VERIFIED_BANK_ACCOUNTS_PER_USER:
            messages.error(
                request,
                f"This user already has the maximum of {MAX_VERIFIED_BANK_ACCOUNTS_PER_USER} bank accounts.",
            )
        else:
            acct_num = (account_no[:120] if account_no else (iban[:120] if iban else "")) or ""
            row = VerifiedBankAccount(
                user=user,
                account_name=account_name[:180],
                account_number=acct_num,
                iban=iban[:80],
                swift_code=swift[:40],
                bank_name=bank_name[:180],
                bank_address=bank_address[:255],
                country=country[:120],
            )
            if auto_verify:
                row.status = VerifiedBankAccount.Status.APPROVED
                row.reviewed_at = timezone.now()
                row.reviewed_by = request.user
            else:
                row.status = VerifiedBankAccount.Status.PENDING
            row.save()
            messages.success(
                request,
                "Bank account saved for withdrawals."
                + (" It is marked verified." if auto_verify else " It is pending review."),
            )

    elif action == "verified_bank_edit":
        rid = (request.POST.get("id") or "").strip()
        row = VerifiedBankAccount.objects.filter(id=rid, user=user).first()
        if not row:
            messages.error(request, "Bank record not found.")
        else:
            account_name = (request.POST.get("account_holder_name") or "").strip()
            account_no = (request.POST.get("account_number") or "").strip()
            bank_name = (request.POST.get("bank_name") or "").strip()
            iban = (request.POST.get("iban") or "").strip()
            swift = (request.POST.get("swift_code") or "").strip()
            country = (request.POST.get("country") or "").strip()
            bank_address = (request.POST.get("bank_address") or "").strip()
            if not account_name or not bank_name or not country:
                messages.error(request, "Account holder name, bank name, and country are required.")
            elif not account_no and not iban:
                messages.error(request, "Provide either an account number or an IBAN.")
            else:
                acct_num = (account_no[:120] if account_no else (iban[:120] if iban else "")) or ""
                row.account_name = account_name[:180]
                row.account_number = acct_num
                row.iban = iban[:80]
                row.swift_code = swift[:40]
                row.bank_name = bank_name[:180]
                row.bank_address = bank_address[:255]
                row.country = country[:120]
                row.save()
                messages.success(request, "Bank account updated.")

    elif action == "verified_bank_delete":
        rid = (request.POST.get("id") or "").strip()
        row = VerifiedBankAccount.objects.filter(id=rid, user=user).first()
        if row:
            row.delete()
            messages.success(request, "Bank account removed.")
        else:
            messages.error(request, "Bank record not found.")

    elif action == "verified_bank_verify":
        rid = (request.POST.get("id") or "").strip()
        row = VerifiedBankAccount.objects.filter(id=rid, user=user).first()
        if not row:
            messages.error(request, "Bank record not found.")
        else:
            row.status = VerifiedBankAccount.Status.APPROVED
            row.reviewed_at = timezone.now()
            row.reviewed_by = request.user
            row.save(update_fields=["status", "reviewed_at", "reviewed_by"])
            messages.success(request, "Bank account marked verified.")

    elif action == "verified_crypto_add":
        wallet_name = (request.POST.get("wallet_name") or "").strip()
        wallet_address = (request.POST.get("wallet_address") or "").strip()
        network = (request.POST.get("crypto_network") or request.POST.get("network") or "").strip()
        auto_verify = request.POST.get("auto_verify") == "on"
        if not wallet_address or not network:
            messages.error(request, "Wallet address and network are required.")
        elif VerifiedCryptoAddress.objects.filter(user=user).count() >= MAX_VERIFIED_CRYPTO_WALLETS_PER_USER:
            messages.error(
                request,
                f"This user already has the maximum of {MAX_VERIFIED_CRYPTO_WALLETS_PER_USER} crypto wallets.",
            )
        else:
            row = VerifiedCryptoAddress(
                user=user,
                wallet_name=wallet_name[:120],
                wallet_address=wallet_address[:255],
                network=network[:80],
            )
            if auto_verify:
                row.status = VerifiedCryptoAddress.Status.APPROVED
                row.reviewed_at = timezone.now()
                row.reviewed_by = request.user
            else:
                row.status = VerifiedCryptoAddress.Status.PENDING
            row.save()
            messages.success(
                request,
                "Crypto wallet saved."
                + (" It is marked verified." if auto_verify else " It is pending review."),
            )

    elif action == "verified_crypto_edit":
        rid = (request.POST.get("id") or "").strip()
        row = VerifiedCryptoAddress.objects.filter(id=rid, user=user).first()
        if not row:
            messages.error(request, "Crypto wallet not found.")
        else:
            wallet_name = (request.POST.get("wallet_name") or "").strip()
            wallet_address = (request.POST.get("wallet_address") or "").strip()
            network = (request.POST.get("crypto_network") or request.POST.get("network") or "").strip()
            if not wallet_address or not network:
                messages.error(request, "Wallet address and network are required.")
            else:
                row.wallet_name = wallet_name[:120]
                row.wallet_address = wallet_address[:255]
                row.network = network[:80]
                row.save()
                messages.success(request, "Crypto wallet updated.")

    elif action == "verified_crypto_delete":
        rid = (request.POST.get("id") or "").strip()
        row = VerifiedCryptoAddress.objects.filter(id=rid, user=user).first()
        if row:
            row.delete()
            messages.success(request, "Crypto wallet removed.")
        else:
            messages.error(request, "Crypto wallet not found.")

    elif action == "verified_crypto_verify":
        rid = (request.POST.get("id") or "").strip()
        row = VerifiedCryptoAddress.objects.filter(id=rid, user=user).first()
        if not row:
            messages.error(request, "Crypto wallet not found.")
        else:
            row.status = VerifiedCryptoAddress.Status.APPROVED
            row.reviewed_at = timezone.now()
            row.reviewed_by = request.user
            row.save(update_fields=["status", "reviewed_at", "reviewed_by"])
            messages.success(request, "Crypto wallet marked verified.")

    elif action == "internal_transfer":
        direction = (request.POST.get("direction") or "").strip()
        try:
            amt = Decimal(str(request.POST.get("amount") or "0"))
        except Exception:
            amt = Decimal("0")
        mt5_id = request.POST.get("mt5_account_id") or ""
        acc = MT5Account.objects.filter(id=mt5_id, user=user).first()
        if not acc or amt <= 0:
            messages.error(request, "Select MT5 account and valid amount.")
        elif direction not in {"wallet_to_mt5", "mt5_to_wallet"}:
            messages.error(request, "Invalid direction.")
        else:
            with db_transaction.atomic():
                u = User.objects.select_for_update().get(pk=user.pk)
                acc = MT5Account.objects.select_for_update().get(pk=acc.pk)
                wb = Decimal(str(u.wallet_balance or 0))
                pw = Decimal(str(u.pending_withdraw or 0))
                available = wb - pw
                bal = Decimal(str(acc.balance or 0))
                if direction == "wallet_to_mt5":
                    if amt > available:
                        messages.error(
                            request,
                            f"Insufficient available wallet balance "
                            f"(wallet {wb}, pending withdraw hold {pw}, available {available}).",
                        )
                    else:
                        u.wallet_balance = wb - amt
                        u.save(update_fields=["wallet_balance"])
                        acc.balance = bal + amt
                        acc.save(update_fields=["balance", "updated_at"])
                        BalanceLedger.objects.create(
                            user=u,
                            entry_type=BalanceLedger.EntryType.TRANSFER_DEBIT,
                            amount=amt,
                            wallet_before=wb,
                            wallet_after=u.wallet_balance,
                            pending_before=Decimal(str(u.pending_withdraw or 0)),
                            pending_after=Decimal(str(u.pending_withdraw or 0)),
                            note=f"Wallet → MT5 {acc.login_id}",
                        )
                        InternalTransfer.objects.create(
                            user=u,
                            transfer_type=InternalTransfer.TransferType.WALLET_TO_TRADING,
                            from_account="WALLET",
                            to_account=f"TRADING:{acc.id}",
                            amount=amt,
                            status=InternalTransfer.Status.APPROVED,
                            processed_at=timezone.now(),
                            processed_by=request.user,
                            note="Admin internal transfer",
                        )
                        messages.success(request, "Transfer completed.")
                elif amt > bal:
                    messages.error(request, "Insufficient MT5 balance.")
                else:
                    acc.balance = bal - amt
                    acc.save(update_fields=["balance", "updated_at"])
                    u.wallet_balance = wb + amt
                    u.save(update_fields=["wallet_balance"])
                    BalanceLedger.objects.create(
                        user=u,
                        entry_type=BalanceLedger.EntryType.TRANSFER_CREDIT,
                        amount=amt,
                        wallet_before=wb,
                        wallet_after=u.wallet_balance,
                        pending_before=Decimal(str(u.pending_withdraw or 0)),
                        pending_after=Decimal(str(u.pending_withdraw or 0)),
                        note=f"MT5 {acc.login_id} → wallet",
                    )
                    InternalTransfer.objects.create(
                        user=u,
                        transfer_type=InternalTransfer.TransferType.TRADING_TO_WALLET,
                        from_account=f"TRADING:{acc.id}",
                        to_account="WALLET",
                        amount=amt,
                        status=InternalTransfer.Status.APPROVED,
                        processed_at=timezone.now(),
                        processed_by=request.user,
                        note="Admin internal transfer",
                    )
                    messages.success(request, "Transfer completed.")

    elif action == "link_ib":
        ib_id = request.POST.get("ib_user_id") or ""
        ib = User.objects.filter(pk=ib_id, role=User.Roles.IB).first()
        if not ib:
            messages.error(request, "Select a valid IB user.")
        else:
            user.referred_by = ib
            user.ib_linked_at = timezone.now()
            user.ib_linked_by = request.user
            user.save(update_fields=["referred_by", "ib_linked_at", "ib_linked_by"])
            messages.success(request, "IB linked.")

    elif action == "unlink_ib":
        user.referred_by = None
        user.ib_linked_at = None
        user.ib_linked_by = None
        user.save(update_fields=["referred_by", "ib_linked_at", "ib_linked_by"])
        messages.success(request, "IB unlinked.")

    elif action == "kyc_approve_manual":
        user.kyc_status = User.KYCStatus.APPROVED
        user.kyc_final_status = User.KYCComponentStatus.VERIFIED
        user.kyc_approved_at = timezone.now()
        user.kyc_approved_by = request.user
        user.save(update_fields=["kyc_status", "kyc_final_status", "kyc_approved_at", "kyc_approved_by"])
        messages.success(request, "KYC marked approved.")

    elif action == "kyc_reject_manual":
        reason = (request.POST.get("reason") or "").strip()
        user.kyc_status = User.KYCStatus.REJECTED
        user.kyc_final_status = User.KYCComponentStatus.REJECTED
        user.kyc_reject_reason = reason
        user.kyc_approved_at = None
        user.kyc_approved_by = None
        user.save(update_fields=["kyc_status", "kyc_final_status", "kyc_reject_reason", "kyc_approved_at", "kyc_approved_by"])
        messages.warning(request, "KYC set to rejected." + (f" Note: {reason}" if reason else ""))

    elif action == "force_password_change":
        user.force_password_change = request.POST.get("enabled") == "1"
        user.save(update_fields=["force_password_change"])
        messages.success(request, "Force password change updated.")

    elif action == "change_main_password":
        new_password = (request.POST.get("new_password") or "").strip()
        if len(new_password) < 8:
            messages.error(request, "Password must be at least 8 characters.")
        else:
            user.set_password(new_password)
            user.save(update_fields=["password"])
            messages.success(request, "Client's main account password changed manually.")

    elif action == "force_email_verified":
        user.email_verified = True
        user.email_verified_at = timezone.now()
        user.is_active = True
        user.email_token = ""
        user.save(update_fields=["email_verified", "email_verified_at", "is_active", "email_token"])
        messages.success(request, "Email verified and account activated.")

    elif action == "force_phone_verified":
        user.phone_verified = True
        user.save(update_fields=["phone_verified"])
        messages.success(request, "Phone marked verified.")

    elif action == "disable_user":
        user.is_active = False
        user.account_status = User.AccountStatus.BLOCKED
        user.save(update_fields=["is_active", "account_status"])
        messages.success(request, "User disabled.")

    elif action == "enable_user":
        if user.role == User.Roles.CLIENT and not user.email_verified:
            messages.error(request, "Verify this client's email before enabling login.")
        else:
            user.is_active = True
            user.account_status = User.AccountStatus.APPROVED
            user.save(update_fields=["is_active", "account_status"])
            messages.success(request, "User enabled.")

    elif action == "user_settings_save":
        r = get_or_create_restriction(user)
        for f in RESTRICTION_BOOL_FIELDS:
            val = str(request.POST.get(f) or "").lower()
            setattr(r, f, val in ["on", "true", "1"])
        r.save()
        if str(request.POST.get("disable_login") or "").lower() in ["on", "true", "1"]:
            user.is_active = False
        else:
            user.is_active = True
        user.save(update_fields=["is_active"])
        if user.role == User.Roles.CLIENT and not user.email_verified:
            messages.warning(request, "User settings saved. Login remains disabled until email is verified.")
        else:
            messages.success(request, "User settings saved.")

    elif action == "upload_document":
        doc_type = (request.POST.get("doc_type") or Document.DocType.OTHER).strip()
        f = request.FILES.get("file")
        if not f:
            messages.error(request, "Choose a file to upload.")
        else:
            verr = validate_document_upload(f)
            if verr:
                messages.error(request, verr)
            else:
                Document.objects.create(
                    user=user,
                    doc_type=doc_type if doc_type in dict(Document.DocType.choices) else Document.DocType.OTHER,
                    file=f,
                    uploaded_by=request.user,
                    status=Document.Status.PENDING,
                )
                recalc_user_kyc(user)
                log_audit(
                    action="admin_client_document_upload",
                    entity_type="user",
                    entity_id=str(user.pk),
                    actor=request.user,
                    channel=AuditLogChannel.ADMIN,
                    request=request,
                    metadata={"doc_type": doc_type},
                )
                messages.success(request, "Document uploaded.")

    elif action == "update_ib_level":
        if user.role != User.Roles.IB:
            messages.error(request, "User is not an IB.")
        else:
            ib_level_id = request.POST.get("ib_level_id")
            selected_level = IBLevel.objects.filter(id=ib_level_id, is_active=True).first() if ib_level_id else None
            
            profile = IBProfile.objects.filter(user=user).first()
            if profile:
                profile.ib_level = selected_level
                profile.save(update_fields=["ib_level"])
                messages.success(request, f"IB Level updated to {selected_level.name if selected_level else 'Default (Starter)'}.")
                
                log_audit(
                    action="admin_update_ib_level",
                    entity_type="user",
                    entity_id=str(user.pk),
                    actor=request.user,
                    channel=AuditLogChannel.ADMIN,
                    request=request,
                    metadata={"new_level_id": ib_level_id, "new_level_name": selected_level.name if selected_level else None},
                )
            else:
                messages.error(request, "User does not have an IB Profile.")

    else:
        messages.error(request, "Unknown action.")

    return redirect(back)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_status_badge_settings(request):
    obj = StatusBadgeSettings.get_solo()
    if request.method == "POST":
        out = {}
        for key, defaults in default_badge_data().items():
            p = f"{key}__"
            out[key] = {
                "enabled": request.POST.get(p + "enabled") == "on",
                "label": (request.POST.get(p + "label") or defaults["label"]).strip(),
                "bg": (request.POST.get(p + "bg") or defaults["bg"]).strip(),
                "fg": (request.POST.get(p + "fg") or defaults["fg"]).strip(),
            }
        obj.data = out
        obj.save(update_fields=["data"])
        messages.success(request, "Status badge settings saved.")
        return redirect("admin-status-badge-settings")
    merged = merge_badge_data(obj.data)
    return render(
        request,
        "admin_panel/user_management/status_badge_settings.html",
        {"title": "Status Settings", "badges": merged},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_create_mt5(request):
    """
    Standalone MT5 creation removed from navigation — use User List → View User → User Details.
    """
    messages.info(
        request,
        "Create MT5 accounts from User Management → User List → open a user → User Details (Create MT5).",
    )
    return redirect("admin-user-list")


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_mt5_list(request):
    qs = MT5Account.objects.select_related("user", "group")
    at = (request.GET.get("account_type") or "").strip().upper()
    if at in (MT5Account.AccountType.LIVE, MT5Account.AccountType.DEMO):
        qs = qs.filter(account_type=at)
    accounts = qs.order_by("-created_at")[:500]
    return render(
        request,
        "admin_panel/user_management/mt5_list.html",
        {"title": "MT5 User List", "accounts": accounts, "filters": {"account_type": at}},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_follow_up_list(request):
    q = (request.GET.get("q") or "").strip()
    per_page = request.GET.get("per_page") or "10"
    sort = (request.GET.get("sort") or "-date_joined").strip()
    export = (request.GET.get("export") or "").lower()
    try:
        per_page_i = int(per_page)
    except ValueError:
        per_page_i = 10
    if per_page_i not in {10, 25, 50, 100}:
        per_page_i = 10
    allowed_sort = {"id", "-id", "first_name", "-first_name", "email", "-email", "country", "-country", "date_joined", "-date_joined"}
    if sort not in allowed_sort:
        sort = "-date_joined"

    rows_qs = _crm_user_list_qs()
    if q:
        rows_qs = rows_qs.filter(
            Q(first_name__icontains=q) | Q(last_name__icontains=q) | Q(email__icontains=q) | Q(phone__icontains=q) | Q(country__icontains=q)
        )
    rows_qs = rows_qs.select_related("referred_by").order_by(sort)

    if export == "excel":
        response = HttpResponse(content_type="text/csv")
        response["Content-Disposition"] = 'attachment; filename="mt5_follow_up_list.csv"'
        writer = csv.writer(response)
        writer.writerow(["ID", "Name", "Email", "Phone", "Country", "Date", "Marketing Name"])
        for u in rows_qs[:5000]:
            writer.writerow([u.id, u.display_name(), u.email, u.phone or "", u.country or "", timezone.localtime(u.date_joined).strftime("%Y-%m-%d %H:%M"), u.referred_by.display_name() if u.referred_by_id else "—"])
        return response

    paginator = Paginator(rows_qs, per_page_i)
    page_obj = paginator.get_page(request.GET.get("page"))
    return render(
        request,
        "admin_panel/user_management/follow_up_list.html",
        {"title": "MT5 Follow Up List", "page_obj": page_obj, "filters": {"q": q, "per_page": per_page_i, "sort": sort}},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_pending_documents_users(request):
    list_status = _parse_list_status(request, "pending")
    query_ex_status = _querystring_excluding(request, "status")

    clients_base = User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER])
    docs_base = Document.objects.filter(user__in=clients_base, doc_type__in=KYC_DOC_TYPES)
    status_counts = get_kyc_queue_status_counts()

    if list_status == "approved":
        doc_status = Document.Status.APPROVED
        detail_param = "APPROVED"
    elif list_status == "rejected":
        doc_status = Document.Status.REJECTED
        detail_param = "REJECTED"
    else:
        doc_status = Document.Status.PENDING
        detail_param = "PENDING"

    user_ids = (
        docs_base.filter(status=doc_status)
        .values_list("user_id", flat=True)
        .distinct()
    )
    users = clients_base.filter(id__in=user_ids).order_by("-date_joined")

    rows = []
    for u in users:
        rows.append(
            {
                "user": u,
                "marketing_name": (u.referred_by.display_name() if u.referred_by_id else "—"),
                "detail_param": detail_param,
            }
        )

    return render(
        request,
        "admin_panel/user_management/pending_documents_users.html",
        {
            "title": "Pending Documents",
            "rows": rows,
            "list_status": list_status,
            "status_counts": status_counts,
            "query_ex_status": query_ex_status,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_documents_approved(request):
    users = (
        User.objects.filter(documents__status=Document.Status.APPROVED)
        .exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER])
        .distinct()
        .order_by("-date_joined")
    )[:500]
    rows = [{"user": u, "marketing_name": (u.referred_by.display_name() if u.referred_by_id else "—")} for u in users]
    return render(request, "admin_panel/user_management/documents_approved.html", {"title": "Approved Documents", "rows": rows})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_documents_all(request):
    back = request.META.get("HTTP_REFERER") or reverse("admin-docs-all")

    if request.method == "POST":
        doc_id = request.POST.get("doc_id") or ""
        action = request.POST.get("action") or ""
        doc = Document.objects.select_related("user").filter(id=doc_id, status=Document.Status.PENDING).first()
        reject_comment = (request.POST.get("reject_comment") or "").strip()
        if not doc:
            messages.error(request, "Document not found or not pending.")
        elif action == "approve":
            doc.status = Document.Status.APPROVED
            doc.reviewed_at = timezone.now()
            doc.reviewed_by = request.user
            doc.review_comment = ""
            doc.save(update_fields=["status", "reviewed_at", "reviewed_by", "review_comment"])
            recalc_user_kyc(doc.user)
            send_event_email(
                _doc_event_key(doc.doc_type, approved=True),
                to_email=doc.user.email,
                user=doc.user,
            )
            _safe_email(
                "Document approved",
                f"Hello {doc.user.display_name()}, your document ({doc.get_doc_type_display()}) has been approved.",
                doc.user.email,
            )
            messages.success(request, f"Approved document #{doc.id}.")
        elif action == "reject":
            if not reject_comment:
                messages.error(request, "Rejection comment is required.")
                return redirect(back)
            doc.status = Document.Status.REJECTED
            doc.reviewed_at = timezone.now()
            doc.reviewed_by = request.user
            doc.review_comment = reject_comment
            doc.save(update_fields=["status", "reviewed_at", "reviewed_by", "review_comment"])
            recalc_user_kyc(doc.user)
            send_event_email(
                _doc_event_key(doc.doc_type, approved=False),
                to_email=doc.user.email,
                user=doc.user,
                extra_context={"reason": reject_comment},
            )
            _safe_email(
                "Document rejected",
                f"Hello {doc.user.display_name()}, your document ({doc.get_doc_type_display()}) was rejected.\nReason: {reject_comment}",
                doc.user.email,
            )
            messages.success(request, f"Rejected document #{doc.id}.")
        else:
            messages.error(request, "Invalid action.")
        return redirect(back)

    docs = Document.objects.select_related("user", "uploaded_by", "reviewed_by").order_by("-uploaded_at")
    user_id = request.GET.get("user_id") or ""
    status = (request.GET.get("status") or "").upper()
    if user_id:
        docs = docs.filter(user_id=user_id)
    if status in {"PENDING", "APPROVED", "REJECTED", "EXPIRED"}:
        docs = docs.filter(status=status)
    return render(
        request,
        "admin_panel/user_management/documents_all.html",
        {"title": "User Documents List", "documents": docs[:500]},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_documents_expired(request):
    today = timezone.localdate()
    newly_expired = list(Document.objects.filter(expires_at__lt=today).exclude(status=Document.Status.EXPIRED).select_related("user")[:500])
    if newly_expired:
        for d in newly_expired:
            _safe_email(
                "Document expired",
                f"Hello {d.user.display_name()}, your document ({d.get_doc_type_display()}) has expired. Please upload a new document.",
                d.user.email,
            )
        admin_emails = list(User.objects.filter(role__in=[User.Roles.ADMIN, User.Roles.BANKER]).exclude(email="").values_list("email", flat=True))
        for admin_email in admin_emails:
            _safe_email(
                "Expired documents detected",
                f"{len(newly_expired)} document(s) moved to expired status.",
                admin_email,
            )

    docs = (
        Document.objects.filter(Q(status=Document.Status.EXPIRED) | Q(expires_at__lt=today))
        .select_related("user")
        .distinct()
        .order_by("-uploaded_at")[:500]
    )
    # Auto-mark records with past expiry date as EXPIRED.
    Document.objects.filter(expires_at__lt=today).exclude(status=Document.Status.EXPIRED).update(status=Document.Status.EXPIRED)
    return render(
        request,
        "admin_panel/user_management/documents_expired.html",
        {"title": "Expired Documents List", "documents": docs, "today": today},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_upload_documents(request):
    clients = _client_users_qs()
    if request.method == "POST":
        uid = request.POST.get("client_id")
        id_file = request.FILES.get("proof_identity")
        addr_file = request.FILES.get("proof_address")
        user = get_object_or_404(clients, pk=uid) if uid else None
        id_err = validate_document_upload(id_file) if id_file else "Document file is required."
        addr_err = validate_document_upload(addr_file) if addr_file else "Document file is required."
        if not user or not id_file or not addr_file:
            messages.error(request, "Select a client and upload both documents.")
        elif id_err or addr_err:
            messages.error(request, id_err or addr_err or "Invalid files.")
        else:
            Document.objects.create(
                user=user,
                doc_type=Document.DocType.NATIONAL_ID,
                file=id_file,
                uploaded_by=request.user,
                status=Document.Status.PENDING,
            )
            Document.objects.create(
                user=user,
                doc_type=Document.DocType.PROOF_OF_ADDRESS,
                file=addr_file,
                uploaded_by=request.user,
                status=Document.Status.PENDING,
            )
            recalc_user_kyc(user)
            send_event_email(
                "kyc_submitted",
                to_email=user.email,
                user=user,
            )
            _safe_email(
                "Documents uploaded",
                f"Hello {user.display_name()}, your POI/POA documents were uploaded and moved to pending verification.",
                user.email,
            )
            messages.success(request, "Documents uploaded.")
            return redirect("admin-docs-all")
    return render(
        request,
        "admin_panel/user_management/upload_documents.html",
        {"title": "Upload User Documents", "clients": clients},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_bank_add(request):
    clients = _client_users_qs()
    if request.method == "POST":
        uid = request.POST.get("client_id")
        user = get_object_or_404(clients, pk=uid) if uid else None
        account_name = (request.POST.get("account_name") or "").strip()
        account_no = (request.POST.get("account_no") or "").strip()
        swift = (request.POST.get("swift_code") or "").strip()
        iban = (request.POST.get("iban") or "").strip()
        bank_name = (request.POST.get("bank_name") or "").strip()
        bank_address = (request.POST.get("bank_address") or "").strip()
        country = (request.POST.get("country") or "").strip()
        if not user or not account_name or not account_no or not bank_name:
            messages.error(request, "Client, account name, account number, and bank name are required.")
        else:
            BankDetails.objects.create(
                user=user,
                payment_channel=BankDetails.PaymentChannel.BANK_TRANSFER,
                account_holder_name=account_name,
                account_number=account_no,
                swift_code=swift,
                iban=iban,
                bank_name=bank_name,
                bank_address=bank_address,
                country=country,
                status=BankDetails.Status.PENDING,
            )
            messages.success(request, "Bank details saved.")
            return redirect("admin-bank-list")
    return render(request, "admin_panel/user_management/bank_add.html", {"title": "Add User Bank Details", "clients": clients})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_bank_list(request):
    rows = BankDetails.objects.select_related("user").order_by("-created_at")[:500]
    return render(request, "admin_panel/user_management/bank_list.html", {"title": "Bank Details List", "rows": rows})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET"])
def um_password_list(request):
    users = _crm_user_list_qs()[:500]
    return render(request, "admin_panel/user_management/password_list.html", {"title": "User Password List", "users": users})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_change_user_password(request):
    clients = _client_users_qs()
    if request.method == "POST":
        uid = request.POST.get("client_id")
        password = request.POST.get("password") or ""
        user = get_object_or_404(clients, pk=uid) if uid else None
        if not user or len(password) < 8:
            messages.error(request, "Select a client and enter a password (min 8 characters).")
        else:
            user.set_password(password)
            user.save(update_fields=["password"])
            _safe_email(
                "Password changed",
                f"Hello {user.display_name()}, your account password has been updated by admin.",
                user.email,
            )
            messages.success(request, "Password updated.")
            return redirect("admin-change-user-password")
    return render(
        request,
        "admin_panel/user_management/change_user_password.html",
        {"title": "Change User Password", "clients": clients},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_add_existing_client(request):
    clients = _client_users_qs()
    groups = MT5Group.objects.all().order_by("name")
    if request.method == "POST":
        uid = request.POST.get("client_id")
        gid = request.POST.get("group_id")
        raw_ids = (request.POST.get("mt5_ids") or "").strip()
        user = get_object_or_404(clients, pk=uid) if uid else None
        group = get_object_or_404(MT5Group, pk=gid) if gid else None
        parts = [p.strip() for p in raw_ids.split(",") if p.strip()]
        if not user or not group or not parts:
            messages.error(request, "Select client, group, and at least one MT5 ID.")
        else:
            created = 0
            for lid in parts:
                if MT5Account.objects.filter(login_id=lid).exists():
                    continue
                MT5Account.objects.create(
                    user=user,
                    account_type=MT5Account.AccountType.LIVE,
                    login_id=lid[:64],
                    server=_mt5_server(),
                    group=group,
                    leverage=100,
                    status=MT5Account.Status.ACTIVE,
                )
                created += 1
            messages.success(request, f"Linked {created} MT5 account(s). Skipped duplicates.")
            return redirect("admin-mt5-list")
    return render(
        request,
        "admin_panel/user_management/add_existing_client.html",
        {"title": "Add Existing Client", "clients": clients, "groups": groups},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_change_mt5_password(request):
    accounts = MT5Account.objects.select_related("user").order_by("-updated_at")[:1000]
    if request.method == "POST":
        aid = request.POST.get("mt5_account_id")
        ptype = (request.POST.get("password_type") or "MAIN").upper()
        main = request.POST.get("main_password") or ""
        inv = request.POST.get("investor_password") or ""
        acc = get_object_or_404(MT5Account, pk=aid) if aid else None
        if not acc:
            messages.error(request, "Select an MT5 account.")
        elif ptype == "MAIN" and not main:
            messages.error(request, "Enter main password.")
        elif ptype == "INVESTOR" and not inv:
            messages.error(request, "Enter investor password.")
        elif ptype == "BOTH" and not (main and inv):
            messages.error(request, "Enter both passwords.")
        else:
            if ptype in ("MAIN", "BOTH") and main:
                acc.set_mt5_password(main)
            if ptype in ("INVESTOR", "BOTH") and inv:
                acc.set_investor_password(inv)
            acc.save(update_fields=["mt5_password_encrypted", "investor_password_encrypted", "updated_at"])
            messages.success(request, "MT5 password(s) updated.")
            return redirect("admin-change-mt5-password")
    return render(
        request,
        "admin_panel/user_management/change_mt5_password.html",
        {"title": "Change MT5 Password", "accounts": accounts},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_update_mt5_leverage(request):
    accounts = MT5Account.objects.select_related("user").order_by("-updated_at")[:1000]
    if request.method == "POST":
        aid = request.POST.get("mt5_account_id")
        lev = request.POST.get("leverage")
        acc = get_object_or_404(MT5Account, pk=aid) if aid else None
        try:
            leverage = int(lev)
        except (TypeError, ValueError):
            leverage = 0
        if not acc or leverage not in LEVERAGE_CHOICES:
            messages.error(request, "Select MT5 account and valid leverage.")
        else:
            acc.leverage = leverage
            acc.save(update_fields=["leverage", "updated_at"])
            messages.success(request, "Leverage updated.")
            return redirect("admin-mt5-update-leverage")
    return render(
        request,
        "admin_panel/user_management/update_mt5_leverage.html",
        {"title": "Update MT5 Leverage", "accounts": accounts, "leverages": LEVERAGE_CHOICES},
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def um_resend_verification(request):
    clients = _client_users_qs()
    if request.method == "POST":
        uid = request.POST.get("client_id")
        user = get_object_or_404(clients, pk=uid) if uid else None
        if not user:
            messages.error(request, "Please select a client.")
        else:
            if not user.email_token:
                user.email_token = secrets.token_hex(16)
            user.email_token_created_at = timezone.now()
            user.save(update_fields=["email_token", "email_token_created_at"])
            verify_url = f"{request.scheme}://{request.get_host()}/verify-email/{user.email_token}/"
            _safe_email(
                "Verify your email",
                f"Hello {user.display_name()},\nPlease verify your email by visiting:\n{verify_url}",
                user.email,
            )
            messages.success(request, "Verification email resent.")
            return redirect("admin-resend-verification")
    return render(request, "admin_panel/user_management/resend_verification.html", {"title": "Resend Verification Mail", "clients": clients})
