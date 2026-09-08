"""Admin KYC review workflow (approve / reject with reason, templated email)."""

from __future__ import annotations

import re

from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods

from accounts.kyc_policy import is_kyc_fully_verified
from accounts.models import Document, KYCAddress, KYCIdentity, User
from accounts.permissions import role_required

from .models import ComplianceSettings
from .services.kyc import get_kyc_queue_status_counts, recalc_user_kyc
from .services.kyc_mail import send_kyc_event_email


def _parse_from_status(request) -> str:
    raw = (request.POST.get("from_status") or request.GET.get("from_status") or "pending").strip().lower()
    if raw in {"pending", "approved", "rejected"}:
        return raw
    return "pending"


def _kyc_review_redirect(request, user_id: int):
    fs = _parse_from_status(request)
    return redirect(f"{reverse('admin-kyc-review', kwargs={'user_id': user_id})}?from_status={fs}")


def _norm_name(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def _identity_doc_types(identity: KYCIdentity | None) -> list[str]:
    if not identity:
        return [Document.DocType.NATIONAL_ID, Document.DocType.PASSPORT]
    raw = (identity.document_type or "").strip().lower()
    if "passport" in raw:
        return [Document.DocType.PASSPORT]
    return [Document.DocType.NATIONAL_ID]


def _compliance_absolute_url(request) -> str:
    return request.build_absolute_uri(reverse("user-compliance"))


def _stamp_kyc_approved_metadata(request, target: User) -> None:
    target.refresh_from_db()
    if not is_kyc_fully_verified(target):
        return
    now = timezone.now()
    target.kyc_approved_by = request.user
    target.kyc_approved_at = now
    target.save(update_fields=["kyc_approved_by", "kyc_approved_at"])


def _maybe_send_account_verified_email(request, target: User) -> None:
    target.refresh_from_db()
    if not is_kyc_fully_verified(target):
        return
    url = _compliance_absolute_url(request)
    send_kyc_event_email(
        "account_verified",
        user=target,
        extra_context={"verify_url": url, "upload_url": url},
        dedupe_once_per_user=True,
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def kyc_review(request, user_id: int):
    target = get_object_or_404(User, id=user_id)
    list_status = _parse_from_status(request)
    status_counts = get_kyc_queue_status_counts()
    query_ex_status = ""
    compliance = ComplianceSettings.get_solo()
    identity = KYCIdentity.objects.filter(user=target).order_by("-created_at").first()
    address = KYCAddress.objects.filter(user=target).order_by("-created_at").first()
    selfie_doc = (
        Document.objects.filter(user=target, doc_type=Document.DocType.SELFIE)
        .order_by("-uploaded_at")
        .first()
    )

    profile_name = target.display_name()
    doc_name = (identity.full_name_on_document if identity else "") or ""
    name_match = bool(_norm_name(profile_name) and _norm_name(doc_name) and _norm_name(profile_name) == _norm_name(doc_name))
    name_unknown = not bool(_norm_name(doc_name))

    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        if action == "save_document_name":
            if identity:
                identity.full_name_on_document = (request.POST.get("full_name_on_document") or "").strip()[:200]
                identity.save(update_fields=["full_name_on_document"])
                messages.success(request, "Document name updated.")
            return _kyc_review_redirect(request, target.id)

        if action == "approve_identity_front":
            now = timezone.now()
            if identity:
                identity.reviewed_at = now
                identity.reviewed_by = request.user
                identity.status = KYCIdentity.Status.PENDING
                identity.save(update_fields=["status", "reviewed_at", "reviewed_by"])
            updated = Document.objects.filter(
                user=target,
                status=Document.Status.PENDING,
                doc_type=Document.DocType.ID_DOCUMENT_FRONT,
            ).update(
                status=Document.Status.APPROVED,
                reviewed_at=now,
                reviewed_by=request.user,
                review_comment="",
            )
            if not updated:
                Document.objects.filter(
                    user=target,
                    status=Document.Status.PENDING,
                    doc_type__in=_identity_doc_types(identity),
                ).update(
                    status=Document.Status.APPROVED,
                    reviewed_at=now,
                    reviewed_by=request.user,
                    review_comment="",
                )
            target.kyc_identity_front_status = User.KYCComponentStatus.VERIFIED
            target.save(update_fields=["kyc_identity_front_status"])
            if (
                target.kyc_identity_front_status == User.KYCComponentStatus.VERIFIED
                and target.kyc_identity_back_status == User.KYCComponentStatus.VERIFIED
                and identity
            ):
                identity.status = KYCIdentity.Status.APPROVED
                identity.save(update_fields=["status"])
            recalc_user_kyc(target)
            url = _compliance_absolute_url(request)
            send_kyc_event_email(
                "identity_approved",
                user=target,
                extra_context={"verify_url": url, "upload_url": url},
                dedupe_seconds=60,
            )
            _stamp_kyc_approved_metadata(request, target)
            _maybe_send_account_verified_email(request, target)
            messages.success(request, "Identity front approved.")
            return _kyc_review_redirect(request, target.id)

        if action == "approve_identity_back":
            now = timezone.now()
            if identity:
                identity.reviewed_at = now
                identity.reviewed_by = request.user
                identity.status = KYCIdentity.Status.PENDING
                identity.save(update_fields=["status", "reviewed_at", "reviewed_by"])
            Document.objects.filter(
                user=target,
                status=Document.Status.PENDING,
                doc_type=Document.DocType.ID_DOCUMENT_BACK,
            ).update(
                status=Document.Status.APPROVED,
                reviewed_at=now,
                reviewed_by=request.user,
                review_comment="",
            )
            target.kyc_identity_back_status = User.KYCComponentStatus.VERIFIED
            target.save(update_fields=["kyc_identity_back_status"])
            if (
                target.kyc_identity_front_status == User.KYCComponentStatus.VERIFIED
                and target.kyc_identity_back_status == User.KYCComponentStatus.VERIFIED
                and identity
            ):
                identity.status = KYCIdentity.Status.APPROVED
                identity.save(update_fields=["status"])
            recalc_user_kyc(target)
            url = _compliance_absolute_url(request)
            send_kyc_event_email(
                "identity_approved",
                user=target,
                extra_context={"verify_url": url, "upload_url": url},
                dedupe_seconds=60,
            )
            _stamp_kyc_approved_metadata(request, target)
            _maybe_send_account_verified_email(request, target)
            messages.success(request, "Identity back approved.")
            return _kyc_review_redirect(request, target.id)

        if action == "approve_address":
            now = timezone.now()
            if address:
                address.status = KYCAddress.Status.APPROVED
                address.reviewed_at = now
                address.reviewed_by = request.user
                address.save(update_fields=["status", "reviewed_at", "reviewed_by"])
            Document.objects.filter(
                user=target,
                status=Document.Status.PENDING,
                doc_type=Document.DocType.PROOF_OF_ADDRESS,
            ).update(status=Document.Status.APPROVED, reviewed_at=now, reviewed_by=request.user, review_comment="")
            target.kyc_address_status = User.KYCComponentStatus.VERIFIED
            target.save(update_fields=["kyc_address_status"])
            recalc_user_kyc(target)
            url = _compliance_absolute_url(request)
            send_kyc_event_email(
                "address_approved",
                user=target,
                extra_context={"verify_url": url, "upload_url": url},
                dedupe_seconds=60,
            )
            _stamp_kyc_approved_metadata(request, target)
            _maybe_send_account_verified_email(request, target)
            if target.kyc_final_status == User.KYCComponentStatus.VERIFIED:
                messages.success(request, "Address verification approved. Account is fully verified.")
            else:
                messages.success(request, "Address verification approved.")
            return _kyc_review_redirect(request, target.id)

        if action in {"reject_identity_front", "reject_identity_back", "reject_address"}:
            reason = (request.POST.get("reject_reason") or "").strip()
            if not reason:
                messages.error(request, "A reject reason is required.")
                return _kyc_review_redirect(request, target.id)
            if action in {"reject_identity_front", "reject_identity_back"} and not identity:
                messages.error(request, "No identity record to reject.")
                return _kyc_review_redirect(request, target.id)
            if action == "reject_address" and not address:
                messages.error(request, "No address record to reject.")
                return _kyc_review_redirect(request, target.id)
            now = timezone.now()
            url = _compliance_absolute_url(request)
            if action == "reject_identity_front" and identity:
                identity.status = KYCIdentity.Status.REJECTED
                identity.reviewed_at = now
                identity.reviewed_by = request.user
                identity.save(update_fields=["status", "reviewed_at", "reviewed_by"])
                target.kyc_identity_front_status = User.KYCComponentStatus.REJECTED
                dq = Document.objects.filter(
                    user=target,
                    status=Document.Status.PENDING,
                    doc_type=Document.DocType.ID_DOCUMENT_FRONT,
                )
                if not dq.exists():
                    dq = Document.objects.filter(
                        user=target,
                        status=Document.Status.PENDING,
                        doc_type__in=_identity_doc_types(identity),
                    )
                dq.update(status=Document.Status.REJECTED, reviewed_at=now, reviewed_by=request.user, review_comment=reason)
            elif action == "reject_identity_back" and identity:
                identity.status = KYCIdentity.Status.REJECTED
                identity.reviewed_at = now
                identity.reviewed_by = request.user
                identity.save(update_fields=["status", "reviewed_at", "reviewed_by"])
                target.kyc_identity_back_status = User.KYCComponentStatus.REJECTED
                dq = Document.objects.filter(
                    user=target,
                    status=Document.Status.PENDING,
                    doc_type=Document.DocType.ID_DOCUMENT_BACK,
                )
                dq.update(status=Document.Status.REJECTED, reviewed_at=now, reviewed_by=request.user, review_comment=reason)
            elif action == "reject_address" and address:
                address.status = KYCAddress.Status.REJECTED
                address.reviewed_at = now
                address.reviewed_by = request.user
                address.save(update_fields=["status", "reviewed_at", "reviewed_by"])
                target.kyc_address_status = User.KYCComponentStatus.REJECTED
                Document.objects.filter(
                    user=target,
                    status=Document.Status.PENDING,
                    doc_type=Document.DocType.PROOF_OF_ADDRESS,
                ).update(status=Document.Status.REJECTED, reviewed_at=now, reviewed_by=request.user, review_comment=reason)
            target.kyc_reject_reason = reason[:2000]
            target.kyc_approved_by = None
            target.kyc_approved_at = None
            target.save(
                update_fields=[
                    "kyc_identity_front_status",
                    "kyc_identity_back_status",
                    "kyc_address_status",
                    "kyc_reject_reason",
                    "kyc_approved_by",
                    "kyc_approved_at",
                ]
            )
            recalc_user_kyc(target)
            if action in {"reject_identity_front", "reject_identity_back"}:
                ok, err = send_kyc_event_email(
                    "identity_rejected",
                    user=target,
                    extra_context={"reason": reason, "verify_url": url, "upload_url": url},
                    dedupe_seconds=30,
                )
            else:
                ok, err = send_kyc_event_email(
                    "address_rejected",
                    user=target,
                    extra_context={"reason": reason, "verify_url": url, "upload_url": url},
                    dedupe_seconds=30,
                )
            if ok and "skipped" not in err:
                messages.success(request, "Rejection recorded and notification sent.")
            elif ok:
                messages.success(request, "Rejection recorded (email skipped by template settings).")
            else:
                messages.warning(request, f"Rejection recorded but email failed: {err}")
            return _kyc_review_redirect(request, target.id)

        messages.error(request, "Invalid action.")
        return _kyc_review_redirect(request, target.id)

    front_exists = bool(identity and identity.front_file and identity.front_file.storage.exists(identity.front_file.name))
    back_exists = bool(identity and identity.back_file and identity.back_file.storage.exists(identity.back_file.name))
    address_exists = bool(address and address.document_file and address.document_file.storage.exists(address.document_file.name))

    return render(
        request,
        "admin_panel/kyc_review.html",
        {
            "u": target,
            "identity": identity,
            "address": address,
            "selfie_doc": selfie_doc,
            "compliance": compliance,
            "profile_name": profile_name,
            "doc_name": doc_name,
            "name_match": name_match,
            "name_unknown": name_unknown,
            "list_status": list_status,
            "status_counts": status_counts,
            "query_ex_status": query_ex_status,
            "front_exists": front_exists,
            "back_exists": back_exists,
            "address_exists": address_exists,
        },
    )
