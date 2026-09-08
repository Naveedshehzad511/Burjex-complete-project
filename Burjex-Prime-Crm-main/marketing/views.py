import json

from django.http import JsonResponse
from django.views.decorators.http import require_http_methods

from accounts.models import User

from .funnel_defaults import get_or_create_website_funnel_campaign
from .models import Lead, SalesFunnelVisitor


@require_http_methods(["POST", "OPTIONS"])
def visitor_capture_submit(request):
    if request.method == "OPTIONS":
        return JsonResponse({})

    if request.content_type and "application/json" in request.content_type:
        try:
            payload = json.loads(request.body.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            payload = {}
        full_name = str(payload.get("full_name", "")).strip()
        email = str(payload.get("email", "")).strip()
        phone = str(payload.get("phone", "")).strip()
        page_url = str(payload.get("page_url", ""))[:500]
        referrer = str(payload.get("referrer", ""))[:500]
    else:
        full_name = request.POST.get("full_name", "").strip()
        email = request.POST.get("email", "").strip()
        phone = request.POST.get("phone", "").strip()
        page_url = request.POST.get("page_url", "")[:500]
        referrer = request.POST.get("referrer", "")[:500]

    if not full_name or not email:
        return JsonResponse({"ok": False, "error": "Full name and email are required."}, status=400)

    campaign = get_or_create_website_funnel_campaign()
    Lead.objects.create(
        campaign=campaign,
        full_name=full_name,
        email=email,
        phone=phone,
        status=Lead.Status.NEW,
    )
    visitor = SalesFunnelVisitor.objects.create(
        full_name=full_name,
        email=email,
        phone=phone,
        page_url=page_url,
        referrer=referrer,
    )
    existing = User.objects.filter(email__iexact=email, role=User.Roles.CLIENT).first()
    if existing:
        visitor.converted_user = existing
        visitor.save(update_fields=["converted_user"])

    return JsonResponse({"ok": True, "id": visitor.id})
