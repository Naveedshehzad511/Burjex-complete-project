from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from admin_panel.models import LegalAgreementSettings, LegalDocument


DOCUMENT_DEFINITIONS = [
    ("terms_conditions_url", LegalDocument.Category.ESSENTIAL, "Terms & Conditions", 10),
    ("privacy_policy_url", LegalDocument.Category.ESSENTIAL, "Privacy Policy", 20),
    ("client_agreement_url", LegalDocument.Category.ESSENTIAL, "Client Agreement", 30),
    ("risk_disclosure_url", LegalDocument.Category.ESSENTIAL, "Risk Disclosure", 40),
    ("aml_policy_url", LegalDocument.Category.ESSENTIAL, "AML Policy", 50),
    ("cookie_policy_url", LegalDocument.Category.ESSENTIAL, "Cookie Policy", 60),
    ("disclaimer_url", LegalDocument.Category.ESSENTIAL, "Disclaimer", 70),
    ("bonus_policy_url", LegalDocument.Category.TRADING, "Bonus Policy", 10),
    ("withdrawal_policy_url", LegalDocument.Category.TRADING, "Withdrawal Policy", 20),
    ("deposit_policy_url", LegalDocument.Category.TRADING, "Deposit Policy", 30),
    ("us_client_policy_url", LegalDocument.Category.REGIONAL, "US Client Policy", 10),
    ("eu_uk_policy_url", LegalDocument.Category.REGIONAL, "EU/UK Policy", 20),
    ("complaints_policy_url", LegalDocument.Category.ADDITIONAL, "Complaints Policy", 10),
    ("conflict_of_interest_url", LegalDocument.Category.ADDITIONAL, "Conflict of Interest", 20),
]


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def legal_agreements_settings_page(request):
    settings_obj = LegalAgreementSettings.get_solo()
    if request.method == "POST":
        action = (request.POST.get("action") or "save").strip().lower()
        if action == "add_custom":
            title = (request.POST.get("custom_title") or "").strip()
            link = (request.POST.get("custom_link") or "").strip()
            file = request.FILES.get("custom_file")
            if title and (link or file):
                next_order = (
                    LegalDocument.objects.filter(category=LegalDocument.Category.CUSTOM).order_by("-order").values_list("order", flat=True).first()
                    or 0
                ) + 10
                doc_obj, created = LegalDocument.objects.update_or_create(
                    category=LegalDocument.Category.CUSTOM,
                    title=title,
                    defaults={
                        "order": next_order,
                        "is_active": True,
                    },
                )
                doc_obj.link = link
                if file:
                    doc_obj.file = file
                doc_obj.save()
                messages.success(request, "Custom legal document saved.")
            else:
                messages.error(request, "Custom document title, and either a link or a file are required.")
            return redirect("admin-legal-agreements")

        if action == "delete_custom":
            LegalDocument.objects.filter(
                id=request.POST.get("id"),
                category=LegalDocument.Category.CUSTOM,
            ).delete()
            messages.success(request, "Custom legal document deleted.")
            return redirect("admin-legal-agreements")

        settings_obj.name = (request.POST.get("name") or "").strip()
        settings_obj.tagline = (request.POST.get("tagline") or "").strip()
        if request.FILES.get("icon"):
            settings_obj.icon = request.FILES["icon"]
        settings_obj.save()

        for field_name, category, title, order in DOCUMENT_DEFINITIONS:
            link = (request.POST.get(field_name) or "").strip()
            file = request.FILES.get(field_name + "_file")
            
            doc_obj, created = LegalDocument.objects.get_or_create(
                category=category,
                title=title,
                defaults={
                    "order": order,
                    "is_active": False,
                }
            )
            doc_obj.link = link
            doc_obj.order = order
            if file:
                doc_obj.file = file
            doc_obj.is_active = bool(doc_obj.link or doc_obj.file)
            doc_obj.save()
        messages.success(request, "Legal agreements settings saved.")
        return redirect("admin-legal-agreements")

    docs = LegalDocument.objects.order_by("category", "order", "id")
    lookup = {(doc.category, doc.title): doc for doc in docs}
    document_objects = {}
    for field_name, category, title, _order in DOCUMENT_DEFINITIONS:
        doc = lookup.get((category, title))
        document_objects[field_name] = doc if doc and doc.is_active else None
    custom_docs = docs.filter(category=LegalDocument.Category.CUSTOM, is_active=True)
    return render(
        request,
        "admin_panel/legal_agreements.html",
        {
            "s": settings_obj,
            "document_objects": document_objects,
            "custom_docs": custom_docs,
        },
    )

from django.contrib import messages
from django.shortcuts import redirect

from admin_panel import org_legal_platform_views


def legal_agreements_settings(request):
    try:
        return org_legal_platform_views.legal_agreements_settings(request)
    except Exception:
        messages.error(request, "Legal Agreements module is temporarily unavailable.")
        return redirect("admin-system-management-dashboard")

