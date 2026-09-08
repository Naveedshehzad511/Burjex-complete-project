from django.shortcuts import redirect, render

from accounts.models import UserRestriction


def _access_denied(request, message: str):
    user = getattr(request, "user", None)
    home_url = "/admin/login/"
    if user and user.is_authenticated:
        home_url = user.staff_home_path()
    return render(
        request,
        "accounts/access_denied.html",
        {"message": message, "home_url": home_url},
        status=403,
    )


class AdminMiddleware:
    """
    Route guards for CRM staff areas:
    - /admin/* (except login/logout): admin/banker only; sales managers redirected to /sales; account managers denied.
    - /sales/*: admin/banker/sales_manager; account managers denied.
    - /manager/*: account managers only; everyone else denied.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path = request.path_info or ""
        user = getattr(request, "user", None)
        authed = bool(user and user.is_authenticated)

        admin_login_exempt = path.startswith("/admin/login") or path.startswith("/admin/logout")

        if path.startswith("/manager/"):
            if not authed:
                return redirect("/admin/login/")
            if not user.is_account_manager():
                return _access_denied(request, "This area is restricted to account managers.")
            return self.get_response(request)

        is_admin_area = path.startswith("/admin/") and not admin_login_exempt
        is_sales_area = path.startswith("/sales/")

        if (is_admin_area or is_sales_area) and not admin_login_exempt:
            if not authed:
                return redirect("/admin/login/")

            if is_admin_area:
                if user.is_admin():
                    return self.get_response(request)
                if user.is_account_manager():
                    return _access_denied(
                        request,
                        "Admin panel access is not permitted for your role. Use your manager dashboard.",
                    )
                if user.is_sales_manager():
                    return redirect("/sales/dashboard/")
                return redirect("/user/dashboard/")

            if is_sales_area:
                if user.can_access_sales_portal():
                    return self.get_response(request)
                if user.is_account_manager():
                    return _access_denied(
                        request,
                        "Sales CRM is not available for your role. Use your manager dashboard.",
                    )
                return redirect("/user/dashboard/")

        return self.get_response(request)


class UserMiddleware:
    """
    Blocks access to `/user/*` routes for admin users.
    Ensures unauthenticated users are redirected to `/user/login/`.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path = request.path_info or ""

        # Allow user login itself.
        if path.startswith("/user/") and path not in {"/user/login/", "/user/login"}:
            user = getattr(request, "user", None)

            if not user or not user.is_authenticated:
                return redirect("/user/login/")

            if user.is_admin():
                return redirect("/admin/dashboard/")
            if user.is_sales_manager():
                return redirect("/sales/dashboard/")
            if user.is_account_manager():
                return redirect("/manager/dashboard/")

            r = UserRestriction.objects.filter(user=user).first()
            if r and r.disable_client_area:
                allow = {"/user/login", "/user/logout", "/accounts/logout"}
                p = path.rstrip("/") or "/"
                if p not in allow and not p.startswith("/user/login"):
                    return render(
                        request,
                        "user_portal/portal_blocked.html",
                        {"message": "Your account has been disabled. Please contact support."},
                        status=403,
                    )

        return self.get_response(request)
