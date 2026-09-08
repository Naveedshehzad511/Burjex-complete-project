from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token
import json, time, urllib.request
User = get_user_model()
u = User.objects.filter(is_staff=False, is_superuser=False, is_active=True).exclude(email__icontains="autodemo").order_by("-id").first()
if not u:
    u = User.objects.filter(is_staff=False, is_active=True).order_by("-id").first()
print(f"USER id={u.id} email={u.email} active={u.is_active}")
token, _ = Token.objects.get_or_create(user=u)
print("TOKEN", token.key)
for action, payload in [
    ("submit_bank", {"action":"submit_bank","account_name":"Live Holder","bank_name":"Live Bank","account_number":f"L{int(time.time())%100000000}","iban":""}),
    ("submit_crypto", {"action":"submit_crypto","crypto_network":"TRC20","wallet_address":f"TLIVE{int(time.time())}"}),
]:
    req = urllib.request.Request(
        "http://127.0.0.1:8000/api/v1/kyc/upload/",
        data=json.dumps(payload).encode(),
        headers={"Content-Type":"application/json","Authorization":f"Token {token.key}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode())
            d = body.get("data") or {}
            print(action, resp.status, body.get("success"), body.get("message"), "bank_ui", d.get("bank_status_ui"), "crypto_ui", d.get("crypto_status_ui"))
    except Exception as e:
        print(action, "ERR", e)
        if hasattr(e, "read"):
            print(e.read().decode()[:400])