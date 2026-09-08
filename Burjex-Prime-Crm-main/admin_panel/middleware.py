from django.shortcuts import redirect
from django.http import JsonResponse

from admin_panel.models import MaintenanceSettings
from admin_panel.services.module_protection import (
    assert_module_writable,
    create_backup_snapshot,
    log_module_change,
)


class MaintenanceModeMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path = (request.path_info or "").strip() or "/"
        if self._is_path_always_allowed(path):
            return self.get_response(request)

        settings_obj = MaintenanceSettings.get_solo()
        if not settings_obj.enabled:
            return self.get_response(request)

        if self._is_admin_path(path):
            return self.get_response(request)

        if self._has_valid_query_bypass(request, settings_obj):
            request.session["maintenance_bypass"] = True
            return self.get_response(request)

        if request.session.get("maintenance_bypass") and (settings_obj.secret_bypass_key or "").strip():
            return self.get_response(request)

        if settings_obj.allow_whitelist_ip and self._ip_is_whitelisted(request, settings_obj.whitelist_ips):
            return self.get_response(request)

        return redirect("/maintenance/")

    @staticmethod
    def _is_path_always_allowed(path: str) -> bool:
        return (
            path == "/maintenance/"
            or path == "/maintenance"
            or path.startswith("/static/")
            or path.startswith("/media/")
            or path.startswith("/health/")
            # REST API + integration webhooks (JSON clients; do not HTML-redirect)
            or path.startswith("/api/")
        )

    @staticmethod
    def _is_admin_path(path: str) -> bool:
        return path.startswith("/admin/") or path.startswith("/sales/") or path.startswith("/django-admin/")

    @staticmethod
    def _has_valid_query_bypass(request, settings_obj: MaintenanceSettings) -> bool:
        key = (settings_obj.secret_bypass_key or "").strip()
        if not key:
            return False
        bypass = (request.GET.get("bypass") or "").strip()
        return bool(bypass and bypass == key)

    @staticmethod
    def _client_ip(request) -> str:
        forwarded = (request.META.get("HTTP_X_FORWARDED_FOR") or "").strip()
        if forwarded:
            return forwarded.split(",")[0].strip()
        return (request.META.get("REMOTE_ADDR") or "").strip()

    def _ip_is_whitelisted(self, request, raw_whitelist: str) -> bool:
        current_ip = self._client_ip(request)
        if not current_ip:
            return False
        allowed = {(x or "").strip() for x in (raw_whitelist or "").split(",")}
        return current_ip in allowed


class ModuleProtectionMiddleware:
    """Global module lock checks + auto-backup for mutating requests."""

    MUTATING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}

    def __init__(self, get_response):
        self.get_response = get_response

    @staticmethod
    def _module_from_path(path: str) -> str:
        p = (path or "").lower()
        if "/integrations/" in p or "/match-trader" in p:
            return "integrations"
        if "/dashboard" in p:
            return "dashboards"
        if "/settings" in p:
            return "settings"
        if "/template" in p or "/portal" in p:
            return "templates"
        return "core"

    def __call__(self, request):
        path = request.path_info or ""
        # REST API / webhooks must not trigger module file backups (login hangs otherwise).
        if path.startswith("/api/"):
            return self.get_response(request)

        if request.method in self.MUTATING_METHODS:
            module_name = self._module_from_path(path)
            try:
                assert_module_writable(module_name)
            except Exception as exc:
                return JsonResponse(
                    {
                        "ok": False,
                        "status": "module_locked",
                        "message": str(exc),
                        "module": module_name,
                    },
                    status=423,
                )

            backup_path = create_backup_snapshot(module_name, changed_by=getattr(request, "user", None))
            log_module_change(
                module_name=module_name,
                changed_by=getattr(request, "user", None),
                change_type="request_update",
                change_summary=f"{request.method} {request.path}",
                changed_paths=[backup_path],
                metadata={"method": request.method, "path": request.path},
            )
        return self.get_response(request)

