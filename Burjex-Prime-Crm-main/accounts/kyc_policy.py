"""Central helpers for portal KYC gates (aligned with ComplianceSettings overrides)."""

from __future__ import annotations

from admin_panel.models import ComplianceSettings

from .models import KYCAddress, KYCIdentity, User


def address_verification_required(compliance: ComplianceSettings | None = None) -> bool:
    """Proof of address is optional unless ComplianceSettings explicitly enables it."""
    compliance = compliance or ComplianceSettings.get_solo()
    return bool(compliance.enable_address_verification)


def is_identity_verified(user: User) -> bool:
    U = User.KYCComponentStatus
    if (
        user.kyc_identity_front_status == U.VERIFIED
        and user.kyc_identity_back_status == U.VERIFIED
    ):
        return True
    return KYCIdentity.objects.filter(user=user, status=KYCIdentity.Status.APPROVED).exists()


def is_kyc_fully_verified(user: User, compliance: ComplianceSettings | None = None) -> bool:
    """True when required KYC components are verified (identity; address only if enabled)."""
    compliance = compliance or ComplianceSettings.get_solo()
    U = User.KYCComponentStatus
    identity_ok = (
        user.kyc_identity_front_status == U.VERIFIED
        and user.kyc_identity_back_status == U.VERIFIED
    )
    if not identity_ok:
        return False
    if address_verification_required(compliance):
        return user.kyc_address_status == U.VERIFIED
    return True


def is_effective_kyc_approved(user: User, compliance: ComplianceSettings | None = None) -> bool:
    """True if CRM considers the client verified for product flows."""
    compliance = compliance or ComplianceSettings.get_solo()
    if is_kyc_fully_verified(user, compliance):
        return True
    if user.kyc_status == User.KYCStatus.APPROVED:
        return True
    if not is_identity_verified(user):
        return False
    if address_verification_required(compliance):
        return KYCAddress.objects.filter(user=user, status=KYCAddress.Status.APPROVED).exists()
    return True


def kyc_blocks_withdraw(user: User, compliance: ComplianceSettings | None = None) -> bool:
    compliance = compliance or ComplianceSettings.get_solo()
    if compliance.allow_withdraw_without_kyc:
        return False
    return not is_effective_kyc_approved(user, compliance)


def kyc_blocks_deposit(user: User, compliance: ComplianceSettings | None = None) -> bool:
    compliance = compliance or ComplianceSettings.get_solo()
    if compliance.allow_deposit_without_kyc:
        return False
    return not is_effective_kyc_approved(user, compliance)


def kyc_blocks_ib_request(user: User, compliance: ComplianceSettings | None = None) -> bool:
    compliance = compliance or ComplianceSettings.get_solo()
    if compliance.allow_ib_request_without_kyc:
        return False
    return not is_effective_kyc_approved(user, compliance)


def kyc_blocks_internal_transfer(user: User, compliance: ComplianceSettings | None = None) -> bool:
    """When treasury requires KYC for transfers, treat like withdrawal gate."""
    from admin_panel.models import TransferTreasurySettings

    ts = TransferTreasurySettings.get_solo()
    compliance = compliance or ComplianceSettings.get_solo()
    if not ts.transfer_require_kyc and not compliance.withdrawal_requires_compliance:
        return False
    if compliance.allow_withdraw_without_kyc:
        return False
    return not is_effective_kyc_approved(user, compliance)
