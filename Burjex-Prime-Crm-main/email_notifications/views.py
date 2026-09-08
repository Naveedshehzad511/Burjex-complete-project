"""Views for email_notifications: tracking pixel endpoint."""

from __future__ import annotations

import base64
import logging

from django.http import HttpResponse
from django.views.decorators.cache import never_cache
from django.views.decorators.csrf import csrf_exempt

from .models import NotificationLog

logger = logging.getLogger(__name__)

# 1x1 transparent GIF (smallest possible valid GIF)
_TRANSPARENT_GIF = base64.b64decode(
    "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
)


@csrf_exempt
@never_cache
def tracking_pixel(request, log_id):
    """Return a 1x1 transparent GIF and mark the notification as opened.

    URL: /email/track/<uuid:log_id>/pixel.png

    This endpoint is embedded as an <img> tag in outgoing notification
    emails. When the recipient's email client loads the image, it
    records the open event in NotificationLog.
    """
    try:
        log_entry = NotificationLog.objects.filter(id=log_id).first()
        if log_entry:
            log_entry.mark_opened()
    except Exception as exc:
        # Never let tracking errors affect the response
        logger.debug("Tracking pixel error for log_id=%s: %s", log_id, exc)

    return HttpResponse(
        _TRANSPARENT_GIF,
        content_type="image/gif",
        headers={
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
            "Expires": "0",
        },
    )
