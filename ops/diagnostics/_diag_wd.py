
import json
from transactions.models import PaymentGateway
from accounts.models import VerifiedBankAccount, VerifiedCryptoAddress
from admin_panel.models import ComplianceSettings, WalletTreasurySettings

out = {}
out["gateways"] = [
    {
        "id": g.id, "name": g.name, "code": g.code, "scope": g.scope,
        "payment_method": g.payment_method, "visibility": g.visibility_status,
        "whitelist_required": g.whitelist_required, "type": g.gateway_type,
    }
    for g in PaymentGateway.objects.all().order_by("id")
]
out["bank_accounts"] = list(VerifiedBankAccount.objects.values("id", "user_id", "bank_name", "status"))
out["crypto_addresses"] = list(VerifiedCryptoAddress.objects.values("id", "user_id", "network", "status"))
cs = ComplianceSettings.get_solo()
ws = WalletTreasurySettings.get_solo()
out["compliance"] = {
    "bank_verification_enabled": getattr(cs, "bank_verification_enabled", None),
    "crypto_verification_enabled": getattr(cs, "crypto_verification_enabled", None),
    "withdrawal_requires_compliance": getattr(cs, "withdrawal_requires_compliance", None),
    "allow_withdraw_without_kyc": getattr(cs, "allow_withdraw_without_kyc", None),
}
out["wallet"] = {
    "wallet_system_enabled": ws.wallet_system_enabled,
    "allow_withdrawals_from_wallet": ws.allow_withdrawals_from_wallet,
    "wallet_withdraw_maintenance": ws.wallet_withdraw_maintenance,
}
print("JSONSTART" + json.dumps(out, default=str) + "JSONEND")
