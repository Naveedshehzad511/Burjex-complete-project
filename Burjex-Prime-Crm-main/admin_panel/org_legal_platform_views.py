from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .models import LegalAgreementsSettings, LegalCustomDocument, OrganizationProfileSettings, TradingPlatform


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def organization_profile_settings(request):
    obj = OrganizationProfileSettings.get_solo()
    if request.method == "POST":
        if not request.user.check_password(request.POST.get("admin_password") or ""):
            messages.error(request, "Admin password is incorrect.")
            return redirect("admin-organization-profile")
        fields = [
            "application_name",
            "company_name",
            "registration_number",
            "support_email",
            "primary_phone",
            "website_url",
            "client_area_url",
            "application_timezone",
            "business_license",
            "incorporation_country",
            "registered_address",
        ]
        for f in fields:
            setattr(obj, f, (request.POST.get(f) or "").strip())
        logo = request.FILES.get("logo")
        if logo:
            obj.logo = logo
        if not obj.domain:
            obj.domain = request.get_host() or obj.domain
        obj.save()
        messages.success(request, "Organization profile settings saved.")
        return redirect("admin-organization-profile")
    if not obj.domain:
        obj.domain = request.get_host() or obj.domain
        obj.save(update_fields=["domain"])
    return render(request, "admin_panel/organization_profile.html", {"s": obj, "title": "Organization Profile"})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def legal_agreements_settings(request):
    s = LegalAgreementsSettings.get_solo()
    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "add_custom":
            name = (request.POST.get("custom_name") or "").strip()
            url = (request.POST.get("custom_url") or "").strip()
            description = (request.POST.get("custom_description") or "").strip()
            if name and url:
                LegalCustomDocument.objects.create(settings=s, name=name, url=url, description=description, is_active=True)
                messages.success(request, "Custom legal document added.")
            else:
                messages.error(request, "Document name and URL are required.")
            return redirect("admin-legal-agreements")
        if action == "delete_custom":
            doc = LegalCustomDocument.objects.filter(id=request.POST.get("id"), settings=s).first()
            if doc:
                doc.delete()
                messages.success(request, "Custom legal document deleted.")
            else:
                messages.error(request, "Document not found.")
            return redirect("admin-legal-agreements")

        for f in [
            "name",
            "tagline",
            "terms_conditions_url",
            "privacy_policy_url",
            "client_agreement_url",
            "risk_disclosure_url",
            "aml_policy_url",
            "cookie_policy_url",
            "disclaimer_url",
            "bonus_credit_policy_url",
            "withdrawal_policy_url",
            "deposit_policy_url",
            "us_client_policy_url",
            "eu_uk_client_policy_url",
            "complaints_policy_url",
            "conflict_interest_policy_url",
        ]:
            setattr(s, f, (request.POST.get(f) or "").strip())
        icon = request.FILES.get("icon")
        if icon:
            s.icon = icon
        s.save()
        messages.success(request, "Legal agreements settings saved.")
        return redirect("admin-legal-agreements")
    custom_docs = s.custom_documents.filter(is_active=True).order_by("id")
    return render(request, "admin_panel/legal_agreements.html", {"s": s, "custom_docs": custom_docs, "title": "Legal Agreements"})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def trading_platform_settings_page(request):
    edit_id = (request.GET.get("edit") or "").strip()
    edit_platform = TradingPlatform.objects.filter(pk=edit_id).first() if edit_id.isdigit() else None
    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        platform_id = (request.POST.get("platform_id") or "").strip()

        if action == "delete":
            obj = TradingPlatform.objects.filter(pk=platform_id).first()
            if obj:
                obj.delete()
                messages.success(request, "Trading platform deleted.")
            else:
                messages.error(request, "Trading platform not found.")
            return redirect("admin-trading-platform-settings")

        obj = TradingPlatform.objects.filter(pk=platform_id).first() if platform_id.isdigit() else TradingPlatform()
        obj.name = (request.POST.get("name") or "").strip()
        obj.tagline = (request.POST.get("tagline") or "").strip()
        obj.web_terminal_link = (request.POST.get("web_terminal_link") or "").strip()
        obj.ios_link = (request.POST.get("ios_link") or "").strip()
        if request.FILES.get("ios_file"):
            obj.ios_file = request.FILES["ios_file"]
        obj.android_link = (request.POST.get("android_link") or "").strip()
        if request.FILES.get("android_file"):
            obj.android_file = request.FILES["android_file"]
        obj.windows_link = (request.POST.get("windows_link") or "").strip()
        if request.FILES.get("windows_file"):
            obj.windows_file = request.FILES["windows_file"]
        obj.mac_link = (request.POST.get("mac_link") or "").strip()
        if request.FILES.get("mac_file"):
            obj.mac_file = request.FILES["mac_file"]
        obj.is_active = request.POST.get("is_active") == "on"
        if request.FILES.get("icon"):
            obj.icon = request.FILES["icon"]
        if not obj.name:
            messages.error(request, "Platform name is required.")
            return redirect("admin-trading-platform-settings")
        obj.save()
        messages.success(request, "Trading platform saved.")
        return redirect("admin-trading-platform-settings")
    platforms = TradingPlatform.objects.all()
    return render(
        request,
        "admin_panel/trading_platform_settings.html",
        {"platforms": platforms, "edit_platform": edit_platform, "title": "Platform Information"},
    )
