from django.conf import settings
from django.db import connection
from django.http import JsonResponse
from django.views.decorators.http import require_GET


@require_GET
def health_live(request):
    """Process is up (for load balancers / k8s liveness)."""
    return JsonResponse({"status": "ok", "service": getattr(settings, "SERVICE_NAME", "crm")})


@require_GET
def health_ready(request):
    """Database reachable (readiness)."""
    try:
        connection.ensure_connection()
    except Exception as exc:
        return JsonResponse({"status": "unready", "db": str(exc)}, status=503)
    return JsonResponse({"status": "ready", "db": "ok"})
