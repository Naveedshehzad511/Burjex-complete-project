from accounts.models import Document, KYCAddress, KYCIdentity, User

# Document types included in admin KYC verification queue (user-level lists + counters).
KYC_QUEUE_DOCUMENT_TYPES = (
    Document.DocType.PASSPORT,
    Document.DocType.NATIONAL_ID,
    Document.DocType.ID_DOCUMENT_FRONT,
    Document.DocType.ID_DOCUMENT_BACK,
    Document.DocType.UTILITY_BILL,
    Document.DocType.PROOF_OF_ADDRESS,
    Document.DocType.SELFIE,
)


def get_kyc_queue_status_counts() -> dict[str, int]:
    """Distinct client users with at least one KYC-queue document in each status."""
    clients_base = User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER])
    docs_base = Document.objects.filter(user__in=clients_base, doc_type__in=KYC_QUEUE_DOCUMENT_TYPES)
    return {
        "pending": docs_base.filter(status=Document.Status.PENDING).values("user_id").distinct().count(),
        "approved": docs_base.filter(status=Document.Status.APPROVED).values("user_id").distinct().count(),
        "rejected": docs_base.filter(status=Document.Status.REJECTED).values("user_id").distinct().count(),
    }


def _address_verification_required() -> bool:
    from admin_panel.models import ComplianceSettings

    return bool(ComplianceSettings.get_solo().enable_address_verification)


def recalc_user_kyc(user):
    """Derive component and final KYC from uploads + admin decisions on the User row.

    Identity (front+back) is always required for approval. Proof of address is only
    required when ComplianceSettings.enable_address_verification is True.
    """
    # If the user was manually approved by an admin (quick action),
    # bypass recalculation so they aren't downgraded due to missing documents.
    if user.kyc_approved_by_id is not None and user.kyc_status == User.KYCStatus.APPROVED:
        U = User.KYCComponentStatus
        if user.kyc_final_status != U.VERIFIED:
            user.kyc_identity_front_status = U.VERIFIED
            user.kyc_identity_back_status = U.VERIFIED
            user.kyc_address_status = U.VERIFIED
            user.kyc_final_status = U.VERIFIED
            user.save(
                update_fields=[
                    "kyc_identity_front_status",
                    "kyc_identity_back_status",
                    "kyc_address_status",
                    "kyc_final_status",
                ]
            )
        return

    U = User.KYCComponentStatus
    address_required = _address_verification_required()
    id_row = KYCIdentity.objects.filter(user=user).order_by("-created_at").first()
    addr_row = KYCAddress.objects.filter(user=user).order_by("-created_at").first()
    front_uploaded = bool(id_row and getattr(id_row, "front_file", None))
    back_uploaded = bool(id_row and getattr(id_row, "back_file", None))
    address_file = bool(addr_row and getattr(addr_row, "document_file", None))

    def identity_side(uploaded: bool, stored: str) -> str:
        if not uploaded:
            return U.INCOMPLETE
        st = (stored or U.INCOMPLETE).lower()
        if st in (U.VERIFIED, U.REJECTED):
            return st
        return U.PENDING

    front_status = identity_side(front_uploaded, user.kyc_identity_front_status)
    back_status = identity_side(back_uploaded, user.kyc_identity_back_status)

    if not address_file:
        address_status = U.INCOMPLETE
    elif addr_row.status == KYCAddress.Status.REJECTED:
        address_status = U.REJECTED
    elif addr_row.status == KYCAddress.Status.APPROVED:
        address_status = U.VERIFIED
    else:
        address_status = U.PENDING

    rejected_parts = [front_status, back_status]
    if address_required:
        rejected_parts.append(address_status)

    identity_verified = front_status == U.VERIFIED and back_status == U.VERIFIED
    address_ok = (not address_required) or (address_status == U.VERIFIED)
    identity_incomplete = front_status == U.INCOMPLETE and back_status == U.INCOMPLETE
    address_incomplete = (not address_required) or (address_status == U.INCOMPLETE)

    if U.REJECTED in rejected_parts:
        final_status = U.REJECTED
        kyc_status = User.KYCStatus.REJECTED
    elif identity_verified and address_ok:
        final_status = U.VERIFIED
        kyc_status = User.KYCStatus.APPROVED
        user.kyc_reject_reason = ""
    elif identity_incomplete and address_incomplete:
        final_status = U.INCOMPLETE
        kyc_status = User.KYCStatus.PENDING
    else:
        final_status = U.PENDING
        kyc_status = User.KYCStatus.PENDING

    user.kyc_identity_front_status = front_status
    user.kyc_identity_back_status = back_status
    user.kyc_address_status = address_status
    user.kyc_final_status = final_status
    user.kyc_status = kyc_status
    user.save(
        update_fields=[
            "kyc_identity_front_status",
            "kyc_identity_back_status",
            "kyc_address_status",
            "kyc_final_status",
            "kyc_status",
            "kyc_reject_reason",
        ]
    )
