"""Public client content from admin-managed Legal / Trading Platform settings."""

from __future__ import annotations

from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.views import APIView

from admin_panel.models import (
    LegalAgreementSettings,
    LegalDocument,
    TradingPlatform,
    TradingPlatformSettings,
)
from admin_panel.settings.legal_agreements.views import DOCUMENT_DEFINITIONS
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
    """Mirrors `/user/legal-agreements/`.

    Reads the SAME rows the admin edits under Settings → Legal Agreements
    (`LegalAgreementSettings` + `LegalDocument`, see
    admin_panel/settings/legal_agreements/views.py) and the web portal renders.
    This used to read `LegalAgreementsSettings` / `LegalCustomDocument` for the
    name, tagline, quick links and custom documents — a second pair of tables
    no wired admin page writes to — so the app always got those back empty.
    The response keys are unchanged.
    """

    permission_classes = [IsAuthenticated]

    def get(self, request):
        settings = LegalAgreementSettings.get_solo()
        docs = LegalDocument.objects.filter(is_active=True).order_by("category", "order", "id")
        by_category: dict[str, list] = {}
        custom: list[dict] = []
        url_by_key: dict[tuple[str, str], str] = {}
        for d in docs:
            url = d.link or _abs(request, d.file)
            if not url:
                continue  # active but nothing to open — the web page would render a dead link
            url_by_key[(d.category, d.title)] = url
            by_category.setdefault(d.category, []).append(
                {
                    "id": d.id,
                    "category": d.category,
                    "category_label": d.get_category_display(),
                    "title": d.title,
                    "link": url,
                    "order": d.order,
                }
            )
            if d.category == LegalDocument.Category.CUSTOM:
                custom.append({"id": d.id, "name": d.title, "url": url, "description": ""})

        # Quick links keyed by the admin form's own field names (single source of truth).
        quick_links = {field: url_by_key.get((cat, title), "") for field, cat, title, _order in DOCUMENT_DEFINITIONS}
        quick_links["bonus_credit_policy_url"] = quick_links.get("bonus_policy_url", "")  # legacy key

        return success_response(
            {
                "name": settings.name or "Legal Agreements",
                "tagline": settings.tagline or "",
                "icon": _abs(request, settings.icon) if settings.icon else "",
                "quick_links": quick_links,
                "documents_by_category": by_category,
                "custom_documents": custom,
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
