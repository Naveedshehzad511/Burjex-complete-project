# ============================================================================
#  Django CRM production image.
#
#  Build context is the CRM project dir, so the compose file passes:
#     context: ../Burjex-Prime-Crm-main
#     dockerfile: ../deploy/crm/Dockerfile
#
#  Django 6.0 requires Python 3.12+.
# ============================================================================
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DJANGO_SETTINGS_MODULE=config.settings

# libpq5   — psycopg2 runtime
# gettext  — manage.py compilemessages (the project ships en/ur/ar locales)
# curl     — container healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 gettext curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./

# requirements.txt is the app's dependency list; the packages below are the
# ones only a production deployment needs and that the list does not pin:
#   gunicorn + uvicorn — ASGI server (config/asgi.py routes HTTP *and* the
#                        live_chat WebSockets, so a WSGI server would drop chat)
#   channels           — imported by config/asgi.py but missing from requirements.txt
#   channels-redis     — cross-process channel layer; the in-memory default
#                        cannot fan out between multiple gunicorn workers
#   certifi            — admin_panel.mail_backend.CertifiEmailBackend
RUN pip install --upgrade pip \
    && pip install -r requirements.txt \
    && pip install \
        "gunicorn>=22,<24" \
        "uvicorn[standard]>=0.30,<1" \
        "channels>=4,<5" \
        "channels-redis>=4,<5" \
        "certifi"

COPY . .

# settings.py configures a FileHandler at BASE_DIR/logs and a backup dir;
# both must exist before Django initialises logging.
RUN mkdir -p /app/logs /app/media /app/staticfiles /app/storage/backups \
    && useradd --create-home --uid 10001 appuser \
    && chown -R appuser:appuser /app

USER appuser

EXPOSE 8000

# Overridden per service in docker-compose.prod.yml (web / worker / beat).
CMD ["gunicorn", "config.asgi:application", \
     "-k", "uvicorn.workers.UvicornWorker", \
     "--bind", "0.0.0.0:8000", "--workers", "3"]
