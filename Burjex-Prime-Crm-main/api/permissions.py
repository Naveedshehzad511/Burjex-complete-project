"""API permission classes mirroring existing portal role gates."""

from __future__ import annotations

from rest_framework.permissions import BasePermission, SAFE_METHODS

from accounts.crm_permissions import user_has_crm_permission
from accounts.models import User


class IsAuthenticatedClient(BasePermission):
    """Client portal roles (same as user_portal PORTAL_ROLES)."""

    message = "Client portal access required."

    def has_permission(self, request, view):
        u = request.user
        if not u or not u.is_authenticated:
            return False
        if u.is_admin() or u.is_sales_manager() or u.is_account_manager():
            return False
        return u.role in {
            User.Roles.CLIENT,
            User.Roles.TRADER,
            User.Roles.COPIER,
            User.Roles.IB,
        }


class IsStaffUser(BasePermission):
    """Admin / banker staff (admin panel)."""

    message = "Staff access required."

    def has_permission(self, request, view):
        u = request.user
        return bool(u and u.is_authenticated and u.is_admin())


class IsSalesPortalUser(BasePermission):
    message = "Sales portal access required."

    def has_permission(self, request, view):
        u = request.user
        return bool(u and u.is_authenticated and u.can_access_sales_portal())


class IsManagerPortalUser(BasePermission):
    message = "Manager portal access required."

    def has_permission(self, request, view):
        u = request.user
        return bool(u and u.is_authenticated and u.can_access_manager_portal())


class IsStaffLoginPortalUser(BasePermission):
    """Anyone who may use /admin/login/ (admin, banker, sales, account manager)."""

    message = "Staff login required."

    def has_permission(self, request, view):
        u = request.user
        return bool(u and u.is_authenticated and u.can_use_staff_login_portal())


class HasCrmPermission(BasePermission):
    """Check a CRM permission code (admins/bankers always pass via user_has_crm_permission)."""

    permission_code: str = ""

    def has_permission(self, request, view):
        u = request.user
        if not u or not u.is_authenticated:
            return False
        code = getattr(view, "crm_permission_code", None) or self.permission_code
        if not code:
            return u.is_admin()
        return user_has_crm_permission(u, code)


def crm_permission(code: str):
    """Factory for view-level CRM permission classes."""

    class _Perm(HasCrmPermission):
        permission_code = code

    _Perm.__name__ = f"CrmPerm_{code.replace('.', '_')}"
    return _Perm
