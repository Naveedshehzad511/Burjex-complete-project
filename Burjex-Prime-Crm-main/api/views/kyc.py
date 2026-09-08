from __future__ import annotations

import logging

from django.core.files.base import ContentFile
from django.db import transaction
from rest_framework.parsers import FormParser, JSONParser, MultiPartParser
from rest_framework.views import APIView

from accounts.models import (
    Document,
    KYCAddress,
    KYCIdentity,
    MAX_VERIFIED_BANK_ACCOUNTS_PER_USER,
    MAX_VERIFIED_CRYPTO_WALLETS_PER_USER,
    User,
    VerifiedBankAccount,
    VerifiedCryptoAddress,
)
from admin_panel.models import BankField, ComplianceSettings, CryptoNetwork, RequiredDocument
from admin_panel.services.kyc import recalc_user_kyc
from admin_panel.services.kyc_mail import send_kyc_event_email
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, success_response, validation_error_response
from enterprise.upload_security import validate_document_upload
from user_portal.views import _create_kyc_staff_notification_once

logger = logging.getLogger(__name__)


def _clone_upload(uploaded, *, suffix: str = "") -> ContentFile:
    """Copy upload bytes so the same file can be saved to multiple FileFields."""
    name = (getattr(uploaded, "name", None) or "upload.bin").strip() or "upload.bin"
    if suffix and "." in name:
        stem, ext = name.rsplit(".", 1)
        name = f"{stem}{suffix}.{ext}"
    elif suffix:
        name = f"{name}{suffix}"
    try:
        if hasattr(uploaded, "seek"):
            uploaded.seek(0)
    except (OSError, AttributeError, ValueError):
        pass
    data = uploaded.read()
    try:
        if hasattr(uploaded, "seek"):
            uploaded.seek(0)
    except (OSError, AttributeError, ValueError):
        pass
    return ContentFile(data, name=name)


def _section_state(row):
    if not row:
        return "NOT_SUBMITTED"
    st = (getattr(row, "status", "") or "").upper()
    if st == "APPROVED":
        return "APPROVED"
    if st == "REJECTED":
        return "REJECTED"
    return "PENDING"


def _ui_status(row):
    if not row:
        return "Not Submitted"
    if row.status == "APPROVED":
        return "Approved"
    if row.status == "REJECTED":
        return "Rejected"
    return "Pending"


def _serialize_identity(row):
    if not row:
        return None
    return {
        "id": row.id,
        "document_type": row.document_type,
        "status": row.status,
        "created_at": row.created_at.isoformat() if row.created_at else None,
        "has_front": bool(getattr(row, "front_file", None)),
        "has_back": bool(getattr(row, "back_file", None)),
    }


def _serialize_address(row):
    if not row:
        return None
    return {
        "id": row.id,
        "document_type": row.document_type,
        "status": row.status,
        "created_at": row.created_at.isoformat() if row.created_at else None,
        "has_document": bool(getattr(row, "document_file", None)),
    }


def _serialize_bank(row):
    if not row:
        return None
    return {
        "id": row.id,
        "account_name": row.account_name,
        "account_number": row.account_number,
        "iban": row.iban,
        "bank_name": row.bank_name,
        "country": row.country,
        "status": row.status,
        "created_at": row.created_at.isoformat() if row.created_at else None,
    }


def _serialize_crypto(row):
    if not row:
        return None
    return {
        "id": row.id,
        "network": row.network,
        "wallet_address": row.wallet_address,
        "wallet_name": row.wallet_name,
        "status": row.status,
        "created_at": row.created_at.isoformat() if row.created_at else None,
    }


def _is_passport_document(document_type: str) -> bool:
    return "passport" in (document_type or "").strip().lower()


def _needs_identity_back(document_type: str) -> bool:
    """Passport is a single-page document; ID card / licence need front + back."""
    return not _is_passport_document(document_type)


def _form_value(data, *keys: str) -> str:
    """Read a single form/JSON value; tolerate list-valued multipart fields."""
    for key in keys:
        if data is None:
            break
        raw = data.get(key) if hasattr(data, "get") else None
        if raw is None:
            continue
        if isinstance(raw, (list, tuple)):
            raw = raw[0] if raw else ""
        text = str(raw).strip()
        if text:
            return text
    return ""


def _posted_bank_fields(data, user: User) -> dict:
    country = _form_value(data, "bank_country", "country") or (getattr(user, "country", None) or "")
    return {
        "account_name": _form_value(data, "account_name", "account_holder_name"),
        "account_number": _form_value(data, "account_number"),
        "iban": _form_value(data, "iban"),
        "swift_code": _form_value(data, "swift_code", "swift"),
        "bank_name": _form_value(data, "bank_name"),
        "bank_address": _form_value(data, "bank_address"),
        "branch": _form_value(data, "branch", "branch_name"),
        "country": str(country).strip(),
    }


def _bank_fields_present(posted: dict) -> bool:
    return bool(
        posted.get("account_name")
        or posted.get("bank_name")
        or posted.get("account_number")
        or posted.get("iban")
    )


def _crypto_fields_present(data) -> bool:
    network = _form_value(data, "crypto_network", "network")
    wallet_address = _form_value(data, "wallet_address", "address")
    return bool(network or wallet_address)


# Mobile + portal always collect these. Extra BankField rows (swift/branch/…)
# default is_required=True in admin and were rejecting app submits.
_BANK_CORE_REQUIRED = frozenset({"account_name", "bank_name"})


def _validate_bank_details(user: User, data, *, status_payload: dict):
    """Validate bank payload. Returns (posted_dict_or_None, error_response_or_None)."""
    if not status_payload.get("bank_can_submit"):
        return None, error_response("Bank details cannot be submitted right now.")
    bank_fields = {f.field_key: f for f in BankField.objects.filter(is_enabled=True)}
    posted = _posted_bank_fields(data, user)

    # Core fields the app/dialog always collects.
    if not posted["account_name"]:
        return None, validation_error_response({"account_name": ["Account holder name is required."]})
    if not posted["bank_name"]:
        return None, validation_error_response({"bank_name": ["Bank name is required."]})
    if not posted["account_number"] and not posted["iban"]:
        return None, error_response("Provide either an account number or an IBAN.")

    # Only enforce admin-required keys that map to fields we actually persist /
    # that the client can send. Never block on unknown/custom keys.
    enforceable = set(posted.keys()) | {"bank_country"}
    for key, meta in bank_fields.items():
        if not meta.is_required:
            continue
        if key not in enforceable and key not in _BANK_CORE_REQUIRED:
            # Optional extras (swift, branch, address, …) — do not hard-fail app.
            continue
        lookup = "country" if key in ("country", "bank_country") else key
        if not posted.get(lookup):
            return None, validation_error_response({key: [f"{meta.label} is required."]})

    bank_count = VerifiedBankAccount.objects.filter(user=user).count()
    row = VerifiedBankAccount.objects.filter(user=user).order_by("-created_at").first()
    can_update = bool(row and row.status != VerifiedBankAccount.Status.APPROVED)
    if not can_update and bank_count >= MAX_VERIFIED_BANK_ACCOUNTS_PER_USER:
        return None, error_response(
            f"You can store at most {MAX_VERIFIED_BANK_ACCOUNTS_PER_USER} bank accounts."
        )
    return posted, None


def _persist_bank_details(user: User, posted: dict) -> None:
    bank_count = VerifiedBankAccount.objects.filter(user=user).count()
    row = VerifiedBankAccount.objects.filter(user=user).order_by("-created_at").first()
    if row and row.status != VerifiedBankAccount.Status.APPROVED:
        row.account_name = posted["account_name"]
        row.account_number = posted["account_number"] or (posted["iban"][:120] if posted["iban"] else "")
        row.iban = posted["iban"]
        row.swift_code = posted["swift_code"]
        row.bank_name = posted["bank_name"]
        row.bank_address = posted["bank_address"]
        row.branch = posted["branch"]
        row.country = posted["country"]
        row.status = VerifiedBankAccount.Status.APPROVED
        row.save()
    elif bank_count < MAX_VERIFIED_BANK_ACCOUNTS_PER_USER:
        acct_num = posted["account_number"] or (posted["iban"][:120] if posted["iban"] else "")
        VerifiedBankAccount.objects.create(
            user=user,
            account_name=posted["account_name"],
            account_number=acct_num,
            iban=posted["iban"],
            swift_code=posted["swift_code"],
            bank_name=posted["bank_name"],
            bank_address=posted["bank_address"],
            branch=posted["branch"],
            country=posted["country"],
            status=VerifiedBankAccount.Status.APPROVED,
        )


def _save_bank_details(user: User, data, *, status_payload: dict):
    """Validate and persist bank details. Returns (ok, error_response_or_None)."""
    posted, err = _validate_bank_details(user, data, status_payload=status_payload)
    if err is not None:
        return False, err
    _persist_bank_details(user, posted)
    return True, None


def _validate_crypto_details(user: User, data, *, status_payload: dict):
    """Validate crypto payload. Returns (posted_dict_or_None, error_response_or_None)."""
    if not status_payload.get("crypto_can_submit"):
        return None, error_response("Crypto details cannot be submitted right now.")
    network = _form_value(data, "crypto_network", "network")
    wallet_address = _form_value(data, "wallet_address", "address")
    wallet_name = _form_value(data, "wallet_name", "label")
    if not network or not wallet_address:
        return None, error_response("Network and wallet address are required.")
    crypto_count = VerifiedCryptoAddress.objects.filter(user=user).count()
    row = VerifiedCryptoAddress.objects.filter(user=user).order_by("-created_at").first()
    can_update = bool(row and row.status != VerifiedCryptoAddress.Status.APPROVED)
    if not can_update and crypto_count >= MAX_VERIFIED_CRYPTO_WALLETS_PER_USER:
        return None, error_response(
            f"You can store at most {MAX_VERIFIED_CRYPTO_WALLETS_PER_USER} crypto wallets."
        )
    return {"network": network, "wallet_address": wallet_address, "wallet_name": wallet_name}, None


def _persist_crypto_details(user: User, posted: dict) -> None:
    crypto_count = VerifiedCryptoAddress.objects.filter(user=user).count()
    row = VerifiedCryptoAddress.objects.filter(user=user).order_by("-created_at").first()
    if row and row.status != VerifiedCryptoAddress.Status.APPROVED:
        row.network = posted["network"]
        row.wallet_address = posted["wallet_address"]
        row.wallet_name = posted["wallet_name"][:120]
        row.status = VerifiedCryptoAddress.Status.APPROVED
        row.save()
    elif crypto_count < MAX_VERIFIED_CRYPTO_WALLETS_PER_USER:
        VerifiedCryptoAddress.objects.create(
            user=user,
            network=posted["network"],
            wallet_address=posted["wallet_address"],
            wallet_name=posted["wallet_name"][:120],
            status=VerifiedCryptoAddress.Status.APPROVED,
        )


def _save_crypto_details(user: User, data, *, status_payload: dict):
    """Validate and persist crypto wallet. Returns (ok, error_response_or_None)."""
    posted, err = _validate_crypto_details(user, data, status_payload=status_payload)
    if err is not None:
        return False, err
    _persist_crypto_details(user, posted)
    return True, None


def build_kyc_status_payload(user: User) -> dict:
    compliance_settings = ComplianceSettings.get_solo()
    recalc_user_kyc(user)
    user.refresh_from_db()

    identity_latest = KYCIdentity.objects.filter(user=user).order_by("-created_at").first()
    address_latest = KYCAddress.objects.filter(user=user).order_by("-created_at").first()
    bank_latest = VerifiedBankAccount.objects.filter(user=user).order_by("-created_at").first()
    crypto_latest = VerifiedCryptoAddress.objects.filter(user=user).order_by("-created_at").first()

    identity_state = _section_state(identity_latest)
    address_state = _section_state(address_latest)
    bank_state = _section_state(bank_latest)
    crypto_state = _section_state(crypto_latest)

    U = User.KYCComponentStatus
    identity_under_review = bool(
        identity_latest
        and identity_latest.status == KYCIdentity.Status.PENDING
        and identity_latest.front_file
        and identity_latest.back_file
    )
    address_under_review = bool(
        address_latest
        and address_latest.status == KYCAddress.Status.PENDING
        and address_latest.document_file
    )
    is_globally_approved = user.kyc_status == User.KYCStatus.APPROVED
    identity_both_verified = is_globally_approved or (
        user.kyc_identity_front_status == U.VERIFIED and user.kyc_identity_back_status == U.VERIFIED
    )
    address_verified_component = is_globally_approved or (user.kyc_address_status == U.VERIFIED)

    identity_can_upload = (
        not identity_both_verified
        and not identity_under_review
        and (
            not identity_latest
            or identity_latest.status == KYCIdentity.Status.REJECTED
            or (
                identity_latest.status == KYCIdentity.Status.PENDING
                and not (identity_latest.front_file and identity_latest.back_file)
            )
        )
    )
    identity_can_delete = bool(
        identity_latest
        and not identity_both_verified
        and not identity_under_review
        and identity_latest.status != KYCIdentity.Status.APPROVED
    )
    address_can_upload = (
        bool(compliance_settings.enable_address_verification)
        and not address_verified_component
        and not address_under_review
        and (
            not address_latest
            or address_latest.status == KYCAddress.Status.REJECTED
            or (
                address_latest.status == KYCAddress.Status.PENDING and not address_latest.document_file
            )
        )
    )
    address_can_delete = bool(
        address_latest
        and not address_verified_component
        and not address_under_review
        and address_latest.status != KYCAddress.Status.APPROVED
    )

    bank_count = VerifiedBankAccount.objects.filter(user=user).count()
    crypto_count = VerifiedCryptoAddress.objects.filter(user=user).count()
    bank_slots_left = max(0, MAX_VERIFIED_BANK_ACCOUNTS_PER_USER - bank_count)
    crypto_slots_left = max(0, MAX_VERIFIED_CRYPTO_WALLETS_PER_USER - crypto_count)
    bank_form_row = bank_latest if bank_latest and bank_latest.status != VerifiedBankAccount.Status.APPROVED else None
    crypto_form_row = (
        crypto_latest if crypto_latest and crypto_latest.status != VerifiedCryptoAddress.Status.APPROVED else None
    )
    # Not Submitted / empty → always allow submit while slots remain (or a
    # non-approved row exists to update). Never hide buttons when UI says Not Submitted.
    bank_can_submit = bool(bank_form_row is not None or bank_slots_left > 0 or bank_latest is None)
    crypto_can_submit = bool(crypto_form_row is not None or crypto_slots_left > 0 or crypto_latest is None)

    return {
        "kyc_status": user.kyc_status,
        "kyc_final_status": user.kyc_final_status,
        "kyc_reject_reason": user.kyc_reject_reason or "",
        "identity_front_status": "verified" if is_globally_approved else user.kyc_identity_front_status,
        "identity_back_status": "verified" if is_globally_approved else user.kyc_identity_back_status,
        "address_component_status": "verified" if is_globally_approved else user.kyc_address_status,
        "identity_state": "APPROVED" if is_globally_approved else identity_state,
        "address_state": "APPROVED" if is_globally_approved else address_state,
        "bank_state": bank_state,
        "crypto_state": crypto_state,
        "identity_status_ui": _ui_status(identity_latest),
        "address_status_ui": _ui_status(address_latest),
        "bank_status_ui": _ui_status(bank_latest),
        "crypto_status_ui": _ui_status(crypto_latest),
        "identity_can_upload": identity_can_upload,
        "identity_can_delete": identity_can_delete,
        "address_can_upload": address_can_upload,
        "address_can_delete": address_can_delete,
        "bank_can_submit": bank_can_submit,
        "crypto_can_submit": crypto_can_submit,
        "address_verification_required": bool(compliance_settings.enable_address_verification),
        "enable_address_verification": bool(compliance_settings.enable_address_verification),
        "all_kyc_approved": identity_both_verified
        and (
            (not compliance_settings.enable_address_verification) or address_verified_component
        ),
        "identity_latest": _serialize_identity(identity_latest),
        "address_latest": _serialize_address(address_latest),
        "bank_latest": _serialize_bank(bank_latest),
        "crypto_latest": _serialize_crypto(crypto_latest),
        "bank_slots_left": bank_slots_left,
        "crypto_slots_left": crypto_slots_left,
        "max_verified_banks": MAX_VERIFIED_BANK_ACCOUNTS_PER_USER,
        "max_verified_crypto": MAX_VERIFIED_CRYPTO_WALLETS_PER_USER,
        "identity_document_options": list(
            RequiredDocument.objects.filter(category=RequiredDocument.Category.IDENTITY, is_enabled=True)
            .order_by("name")
            .values("id", "name")
        ),
        "address_document_options": list(
            RequiredDocument.objects.filter(category=RequiredDocument.Category.ADDRESS, is_enabled=True)
            .order_by("name")
            .values("id", "name")
        ),
        "crypto_network_options": list(
            CryptoNetwork.objects.filter(is_enabled=True).order_by("label").values("id", "label", "code")
        ),
        "bank_field_settings": list(
            BankField.objects.filter(is_enabled=True).order_by("id").values(
                "field_key", "label", "is_required"
            )
        ),
    }


class KYCStatusAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]

    def get(self, request):
        return success_response(
            build_kyc_status_payload(request.user),
            message="KYC status retrieved successfully.",
        )


class KYCUploadAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]
    # JSON for bank/crypto (no files); multipart for identity/address uploads.
    parser_classes = [JSONParser, MultiPartParser, FormParser]

    def post(self, request):
        action = _form_value(request.data, "action")
        user = request.user
        compliance_settings = ComplianceSettings.get_solo()
        status_payload = build_kyc_status_payload(user)

        if action == "delete_identity":
            if not status_payload["identity_can_delete"]:
                return error_response("You cannot delete identity documents in the current status.")
            row = KYCIdentity.objects.filter(user=user, id=request.data.get("id")).first()
            if row and row.status != KYCIdentity.Status.APPROVED:
                Document.objects.filter(
                    user=user,
                    status=Document.Status.PENDING,
                    doc_type__in=(
                        Document.DocType.ID_DOCUMENT_FRONT,
                        Document.DocType.ID_DOCUMENT_BACK,
                        Document.DocType.NATIONAL_ID,
                        Document.DocType.PASSPORT,
                    ),
                ).delete()
                row.delete()
                recalc_user_kyc(user)
            return success_response(build_kyc_status_payload(user), message="Identity record deleted.")

        if action == "delete_address":
            if not status_payload["address_can_delete"]:
                return error_response("You cannot delete address documents in the current status.")
            row = KYCAddress.objects.filter(user=user, id=request.data.get("id")).first()
            if row and row.status != KYCAddress.Status.APPROVED:
                Document.objects.filter(
                    user=user,
                    status=Document.Status.PENDING,
                    doc_type=Document.DocType.PROOF_OF_ADDRESS,
                ).delete()
                row.delete()
                recalc_user_kyc(user)
            return success_response(build_kyc_status_payload(user), message="Address record deleted.")

        if action == "delete_bank":
            row = VerifiedBankAccount.objects.filter(user=user, id=request.data.get("id")).first()
            if row and row.status != VerifiedBankAccount.Status.APPROVED:
                row.delete()
            return success_response(build_kyc_status_payload(user), message="Bank record deleted.")

        if action == "delete_crypto":
            row = VerifiedCryptoAddress.objects.filter(user=user, id=request.data.get("id")).first()
            if row and row.status != VerifiedCryptoAddress.Status.APPROVED:
                row.delete()
            return success_response(build_kyc_status_payload(user), message="Crypto record deleted.")

        if action == "upload_identity":
            if not status_payload["identity_can_upload"]:
                return error_response("Identity verification cannot be updated right now.")
            if (
                compliance_settings.identity_lock_after_approval
                and KYCIdentity.objects.filter(user=user, status=KYCIdentity.Status.APPROVED).exists()
            ):
                return error_response("Identity already verified.")
            document_type = _form_value(request.data, "identity_document_type") or "Passport"
            needs_back = _needs_identity_back(document_type)
            front = request.FILES.get("identity_front")
            back = request.FILES.get("identity_back")
            err = validate_document_upload(front)
            if err:
                return error_response(err)
            if needs_back:
                err = validate_document_upload(back)
                if err:
                    return error_response(err or "Front and back images are required for this document type.")
            elif not back:
                # Passport: single page — reuse front so admin front/back review stays consistent.
                back = front

            # Clone bytes before multi-field saves (UploadedFile streams are single-pass).
            front_identity = _clone_upload(front, suffix="_id_front")
            back_src = back if back is not None else front
            back_identity = _clone_upload(back_src, suffix="_id_back")
            front_doc = _clone_upload(front, suffix="_doc_front")
            back_doc = _clone_upload(back_src, suffix="_doc_back")

            include_bank = _bank_fields_present(_posted_bank_fields(request.data, user))
            include_crypto = _crypto_fields_present(request.data)
            bank_posted = None
            crypto_posted = None
            if include_bank:
                bank_posted, bank_err = _validate_bank_details(
                    user, request.data, status_payload=status_payload
                )
                if bank_err is not None:
                    return bank_err
            if include_crypto:
                crypto_posted, crypto_err = _validate_crypto_details(
                    user, request.data, status_payload=status_payload
                )
                if crypto_err is not None:
                    return crypto_err

            try:
                with transaction.atomic():
                    Document.objects.filter(
                        user=user,
                        status=Document.Status.PENDING,
                        doc_type__in=(
                            Document.DocType.ID_DOCUMENT_FRONT,
                            Document.DocType.ID_DOCUMENT_BACK,
                            Document.DocType.NATIONAL_ID,
                            Document.DocType.PASSPORT,
                        ),
                    ).delete()
                    if compliance_settings.identity_allow_multiple_documents:
                        KYCIdentity.objects.create(
                            user=user,
                            document_type=document_type,
                            expiry_date=None,
                            front_file=front_identity,
                            back_file=back_identity,
                            status=KYCIdentity.Status.PENDING,
                        )
                    else:
                        row = KYCIdentity.objects.filter(user=user).order_by("-created_at").first()
                        if row and row.status != KYCIdentity.Status.APPROVED:
                            row.document_type = document_type
                            row.expiry_date = None
                            row.front_file = front_identity
                            row.back_file = back_identity
                            row.status = KYCIdentity.Status.PENDING
                            row.save()
                        else:
                            KYCIdentity.objects.create(
                                user=user,
                                document_type=document_type,
                                expiry_date=None,
                                front_file=front_identity,
                                back_file=back_identity,
                                status=KYCIdentity.Status.PENDING,
                            )
                    user.kyc_status = User.KYCStatus.PENDING
                    user.kyc_reject_reason = ""
                    user.kyc_identity_front_status = User.KYCComponentStatus.PENDING
                    user.kyc_identity_back_status = User.KYCComponentStatus.PENDING
                    user.save(
                        update_fields=[
                            "kyc_status",
                            "kyc_reject_reason",
                            "kyc_identity_front_status",
                            "kyc_identity_back_status",
                        ]
                    )
                    recalc_user_kyc(user)
                    Document.objects.create(
                        user=user,
                        doc_type=Document.DocType.ID_DOCUMENT_FRONT,
                        file=front_doc,
                        uploaded_by=user,
                        status=Document.Status.PENDING,
                    )
                    Document.objects.create(
                        user=user,
                        doc_type=Document.DocType.ID_DOCUMENT_BACK,
                        file=back_doc,
                        uploaded_by=user,
                        status=Document.Status.PENDING,
                    )
                    if bank_posted is not None:
                        _persist_bank_details(user, bank_posted)
                    if crypto_posted is not None:
                        _persist_crypto_details(user, crypto_posted)
            except Exception:
                logger.exception("Identity upload failed", extra={"user_id": user.id})
                return error_response("Unable to submit identity documents. Please try again.")
            try:
                send_kyc_event_email("identity_submitted", user=user, dedupe_seconds=120)
            except Exception:
                logger.exception("Identity submitted email failed", extra={"user_id": user.id})
            try:
                _create_kyc_staff_notification_once(user)
            except Exception:
                logger.exception("KYC staff notify failed (identity)", extra={"user_id": user.id})
            msg = "Identity documents submitted."
            if include_bank or include_crypto:
                parts = ["Identity"]
                if include_bank:
                    parts.append("bank")
                if include_crypto:
                    parts.append("crypto")
                msg = " / ".join(parts) + " details submitted."
            return success_response(build_kyc_status_payload(user), message=msg)

        if action == "upload_address":
            if not status_payload["address_can_upload"]:
                return error_response("Address verification cannot be updated right now.")
            if (
                compliance_settings.address_lock_after_approval
                and KYCAddress.objects.filter(user=user, status=KYCAddress.Status.APPROVED).exists()
            ):
                return error_response("Address already verified.")
            address_file = request.FILES.get("address_file")
            address_type = _form_value(request.data, "address_document_type") or "Utility Bill"
            err = validate_document_upload(address_file)
            if err:
                return error_response(err)
            address_kyc = _clone_upload(address_file, suffix="_addr")
            address_doc = _clone_upload(address_file, suffix="_addr_doc")
            try:
                with transaction.atomic():
                    Document.objects.filter(
                        user=user,
                        status=Document.Status.PENDING,
                        doc_type=Document.DocType.PROOF_OF_ADDRESS,
                    ).delete()
                    row = KYCAddress.objects.filter(user=user).order_by("-created_at").first()
                    if row and row.status != KYCAddress.Status.APPROVED:
                        row.document_type = address_type
                        row.document_file = address_kyc
                        row.status = KYCAddress.Status.PENDING
                        row.save()
                    else:
                        KYCAddress.objects.create(
                            user=user,
                            document_type=address_type,
                            document_file=address_kyc,
                            status=KYCAddress.Status.PENDING,
                        )
                    user.kyc_status = User.KYCStatus.PENDING
                    user.kyc_reject_reason = ""
                    user.kyc_address_status = User.KYCComponentStatus.PENDING
                    user.save(
                        update_fields=["kyc_status", "kyc_reject_reason", "kyc_address_status"]
                    )
                    recalc_user_kyc(user)
                    Document.objects.create(
                        user=user,
                        doc_type=Document.DocType.PROOF_OF_ADDRESS,
                        file=address_doc,
                        uploaded_by=user,
                        status=Document.Status.PENDING,
                    )
            except Exception:
                logger.exception("Address upload failed", extra={"user_id": user.id})
                return error_response("Unable to submit address document. Please try again.")
            try:
                send_kyc_event_email("address_submitted", user=user, dedupe_seconds=120)
            except Exception:
                logger.exception("Address submitted email failed", extra={"user_id": user.id})
            try:
                _create_kyc_staff_notification_once(user)
            except Exception:
                logger.exception("KYC staff notify failed (address)", extra={"user_id": user.id})
            return success_response(build_kyc_status_payload(user), message="Address document submitted.")

        if action in ("upload_bank", "submit_bank"):
            ok, bank_err = _save_bank_details(user, request.data, status_payload=status_payload)
            if not ok:
                return bank_err
            return success_response(build_kyc_status_payload(user), message="Bank details saved.")

        if action in ("upload_crypto", "submit_crypto"):
            ok, crypto_err = _save_crypto_details(user, request.data, status_payload=status_payload)
            if not ok:
                return crypto_err
            return success_response(build_kyc_status_payload(user), message="Crypto details saved.")

        return error_response("Invalid action.")
