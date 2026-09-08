from typing import Iterable

from django.contrib.auth.decorators import user_passes_test
from django.http import HttpResponseForbidden

from .models import User


def role_required(allowed_roles: Iterable[str]):
    allowed_roles_set = set(allowed_roles)

    def predicate(u: User) -> bool:
        if not u.is_authenticated:
            return False
        return u.role in allowed_roles_set

    return user_passes_test(predicate)


def _sales_portal_ok(u: User) -> bool:
    return u.is_authenticated and u.can_access_sales_portal()


sales_portal_required = user_passes_test(_sales_portal_ok, login_url="/admin/login/")


def crm_perm_required(permission_code: str):
    """Deny with 403 if the user lacks this CRM permission (admins/bankers always pass)."""

    def decorator(view_func):
        from functools import wraps

        from django.shortcuts import redirect

        @wraps(view_func)
        def _wrapped(request, *args, **kwargs):
            from accounts.crm_permissions import user_has_crm_permission

            u = request.user
            if not u.is_authenticated:
                return redirect("/admin/login/")
            if not user_has_crm_permission(u, permission_code):
                return HttpResponseForbidden("You do not have permission for this action.")
            return view_func(request, *args, **kwargs)

        return _wrapped

    return decorator

