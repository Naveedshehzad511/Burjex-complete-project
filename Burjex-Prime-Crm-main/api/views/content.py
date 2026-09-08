"""Public client content from admin-managed Legal / Trading Platform settings."""

from __future__ import annotations

from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.views import APIView

from admin_panel.models import (
    LegalAgreementsSettings,
    LegalCustomDocument,
    LegalDocument,
    TradingPlatform,
    TradingPlatformSettings,
)
from api.responses import success_response


def _abs(request, url_or_file) -> str:
    if not url_or_file:
        return ""
    try:
        url = url_or_file.url if hasattr(url_or_file, "url") else str(url_or_file)
    except Exception:
        url = str(url_or_file)
    if not url:
        return ""
    if url.startswith("http://") or url.startswith("https://"):
        return url
    return request.build_absolute_uri(url)


class LegalAgreementsAPIView(APIView):
    """Mirrors `/user/legal-agreements/` using admin LegalDocument + settings."""

    permission_classes = [IsAuthenticated]

    def get(self, request):
        settings = LegalAgreementsSettings.get_solo()
        docs = LegalDocument.objects.filter(is_active=True).order_by("category", "order", "id")
        custom = LegalCustomDocument.objects.filter(settings=settings, is_active=True).order_by(
            "sort_order", "id"
        )
        by_category: dict[str, list] = {}
        for d in docs:
            by_category.setdefault(d.category, []).append(
                {
                    "id": d.id,
                    "category": d.category,
                    "category_label": d.get_category_display(),
                    "title": d.title,
                    "link": d.link or _abs(request, d.file),
                    "order": d.order,
                }
            )
        return success_response(
            {
                "name": settings.name or "Legal Agreements",
                "tagline": settings.tagline or "",
                "quick_links": {
                    "terms_conditions_url": settings.terms_conditions_url,
                    "privacy_policy_url": settings.privacy_policy_url,
                    "client_agreement_url": settings.client_agreement_url,
                    "risk_disclosure_url": settings.risk_disclosure_url,
                    "aml_policy_url": settings.aml_policy_url,
                    "cookie_policy_url": settings.cookie_policy_url,
                    "disclaimer_url": settings.disclaimer_url,
                    "bonus_credit_policy_url": settings.bonus_credit_policy_url,
                    "withdrawal_policy_url": settings.withdrawal_policy_url,
                    "deposit_policy_url": settings.deposit_policy_url,
                },
                "documents_by_category": by_category,
                "custom_documents": [
                    {
                        "id": c.id,
                        "name": c.name,
                        "url": c.url,
                        "description": c.description or "",
                    }
                    for c in custom
                ],
            },
            message="Legal agreements retrieved successfully.",
        )


class TradingPlatformsAPIView(APIView):
    """Mirrors `/user/trading-platform/` download/links from admin."""

    permission_classes = [AllowAny]

    def get(self, request):
        solo = TradingPlatformSettings.get_solo()
        platforms = TradingPlatform.objects.filter(is_active=True).order_by("name")
        return success_response(
            {
                "settings": {
                    "platform_name": solo.platform_name or "Trading Platform",
                    "tagline": solo.tagline or "",
                    "web_terminal_link": solo.web_terminal_link,
                    "ios_download_link": solo.ios_download_link,
                    "android_download_link": solo.android_download_link,
                    "windows_download_link": solo.windows_download_link,
                    "macos_download_link": solo.macos_download_link,
                    "icon": _abs(request, solo.platform_icon) if solo.platform_icon else "",
                },
                "platforms": [
                    {
                        "id": p.id,
                        "name": p.name,
                        "tagline": p.tagline or "",
                        "icon": _abs(request, p.icon) if p.icon else "",
                        "web_terminal_link": p.web_terminal_link,
                        "ios_link": p.ios_link or _abs(request, p.ios_file),
                        "android_link": p.android_link or _abs(request, p.android_file),
                        "windows_link": p.windows_link or _abs(request, p.windows_file),
                        "mac_link": p.mac_link or _abs(request, p.mac_file),
                    }
                    for p in platforms
                ],
            },
            message="Trading platforms retrieved successfully.",
        )
