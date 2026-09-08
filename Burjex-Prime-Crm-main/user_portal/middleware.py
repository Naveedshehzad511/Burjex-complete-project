"""Graceful degradation when client portal templates are missing."""

from django.conf import settings
from django.http import HttpResponse
from django.template import TemplateDoesNotExist
from django.template.loader import render_to_string


class PortalTemplateFallbackMiddleware:
    """
    Catches TemplateDoesNotExist for /user/* and returns a simple fallback page
    instead of a 500 error.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        try:
            return self.get_response(request)
        except TemplateDoesNotExist as exc:
            path = getattr(request, "path", "") or ""
            if not path.startswith("/user/"):
                raise
            ctx = {
                "missing_template": str(exc) if settings.DEBUG else None,
            }
            try:
                html = render_to_string("user_portal/fallback_layout.html", ctx, request=request)
            except Exception:
                html = (
                    "<!DOCTYPE html><html lang=en><meta charset=utf-8><meta name=viewport "
                    "content='width=device-width,initial-scale=1'><title>Client Portal</title>"
                    "<body style='font-family:system-ui;padding:2rem;max-width:36rem;margin:auto'>"
                    "<h1 style='font-size:1.25rem'>Client portal</h1>"
                    "<p style='color:#64748b'>The portal could not be displayed. Please try again later.</p>"
                    "</body></html>"
                )
            return HttpResponse(html, status=200, content_type="text/html; charset=utf-8")
