"""
Deployment split (env-driven). Point each process at one role behind a load balancer.

Suggested env:
  SERVICE_NAME=crm|trading|payment|reporting
  REDIS_URL=redis://...
  CELERY_BROKER_URL=redis://.../0
"""

from django.conf import settings


def service_name() -> str:
    return getattr(settings, "SERVICE_NAME", "crm")


def is_crm_service() -> bool:
    return service_name().lower() in ("", "crm", "web", "django")
