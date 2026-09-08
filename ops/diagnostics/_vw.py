
import json
from django.test import RequestFactory
from accounts.models import User
from api.services import treasury_service
from api.views.treasury import WithdrawMethodsAPIView

treasury_service.ensure_default_withdraw_gateways()
print("GATEWAYS:")
for g in treasury_service.withdraw_gateways():
    print(" ", g["id"], g["code"], g["payment_method"], g["scope"], g["visibility_status"], g["can_use"])

u = User.objects.filter(verified_bank_accounts__isnull=False).distinct().first()
if u is None:
    print("no user with bank accounts")
else:
    rf = RequestFactory()
    req = rf.get("/api/v1/withdrawals/methods/")
    req.user = u
    resp = WithdrawMethodsAPIView.as_view()(req)
    resp.render()
    data = json.loads(resp.content)["data"]
    print("USER:", u.id, u.email)
    print("METHODS:")
    for m in data["methods"]:
        print(" ", m["key"], "| gateway=", m["gateway"], "| enabled=", m["enabled"],
              "| accounts=", [(a["id"], a["label"]) for a in m["accounts"]])
