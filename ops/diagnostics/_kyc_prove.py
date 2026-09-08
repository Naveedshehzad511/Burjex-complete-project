from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token
from api.views.kyc import build_kyc_status_payload, _validate_bank_details, _validate_crypto_details, _persist_bank_details, _persist_crypto_details
import time
User = get_user_model()
u = User.objects.filter(is_staff=False, is_superuser=False).order_by("-id").first()
print(f"USER id={u.id} email={u.email}")
payload = build_kyc_status_payload(u)
print("bank_can_submit", payload.get("bank_can_submit"), "crypto_can_submit", payload.get("crypto_can_submit"))
token, _ = Token.objects.get_or_create(user=u)
print("TOKEN", token.key)
bank_data = {"account_name": "API Test Holder", "bank_name": "Test Bank", "account_number": f"T{int(time.time())%100000000}", "iban": ""}
posted, err = _validate_bank_details(u, bank_data, status_payload=payload)
print("bank_validate_ok", posted is not None)
if err is not None:
    print("bank_err", getattr(err, "data", err))
if posted:
    _persist_bank_details(u, posted)
    print("bank_persisted OK")
payload2 = build_kyc_status_payload(u)
crypto_data = {"crypto_network": "TRC20", "wallet_address": f"TTEST{int(time.time())}ADDR"}
cposted, cerr = _validate_crypto_details(u, crypto_data, status_payload=payload2)
print("crypto_validate_ok", cposted is not None)
if cerr is not None:
    print("crypto_err", getattr(cerr, "data", cerr))
if cposted:
    _persist_crypto_details(u, cposted)
    print("crypto_persisted OK")
final = build_kyc_status_payload(u)
print("FINAL bank", final.get("bank_status_ui"), "can", final.get("bank_can_submit"))
print("FINAL crypto", final.get("crypto_status_ui"), "can", final.get("crypto_can_submit"))
import json, urllib.request
req = urllib.request.Request(
    "http://127.0.0.1:8000/api/v1/kyc/upload/",
    data=json.dumps({"action":"submit_bank","account_name":"HTTP Bank","bank_name":"HTTP Bank Co","account_number":f"H{int(time.time())%100000000}","iban":""}).encode(),
    headers={"Content-Type":"application/json","Authorization":f"Token {token.key}"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode())
        print("HTTP_BANK", resp.status, body.get("success"), body.get("message"))
except Exception as e:
    print("HTTP_BANK_ERR", e)
    if hasattr(e, 'read'):
        print(e.read().decode()[:500])
req2 = urllib.request.Request(
    "http://127.0.0.1:8000/api/v1/kyc/upload/",
    data=json.dumps({"action":"submit_crypto","crypto_network":"ERC20","wallet_address":f"0xHTTP{int(time.time())}"}).encode(),
    headers={"Content-Type":"application/json","Authorization":f"Token {token.key}"},
    method="POST",
)
try:
    with urllib.request.urlopen(req2, timeout=30) as resp:
        body = json.loads(resp.read().decode())
        print("HTTP_CRYPTO", resp.status, body.get("success"), body.get("message"))
except Exception as e:
    print("HTTP_CRYPTO_ERR", e)
    if hasattr(e, 'read'):
        print(e.read().decode()[:500])