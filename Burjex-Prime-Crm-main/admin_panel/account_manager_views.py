"""Account Manager (MANAGER role) provisioning — admin/banker only."""
from __future__ import annotations

from django.contrib import messages
from django.db import transaction
from django.db.models import Count
from django.shortcuts import get_object_or_404, redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .crm_org_views import _active_target_for_template, _save_manager_target_from_post
from .models import ManagerAssignedClient, ManagerPortalPermission, ManagerTarget

_ADMIN = role_required([User.Roles.ADMIN, User.Roles.BANKER])


def _perm_from_post(post) -> dict[str, bool]:
    return {
        "view_clients": post.get("perm_view_clients") == "on",
        "view_deposit": post.get("perm_view_deposit") == "on",
        "view_withdrawal": post.get("perm_view_withdrawal") == "on",
        "view_volume": post.get("perm_view_volume") == "on",
        "view_balance": post.get("perm_view_balance") == "on",
        "view_trades": post.get("perm_view_trades") == "on",
        "view_personal_info": post.get("perm_view_personal_info") == "on",
    }


@_ADMIN
@require_http_methods(["GET"])
def account_managers_list(request):
    rows = (
        User.objects.filter(role=User.Roles.MANAGER)
        .annotate(assigned_count=Count("manager_portal_assignments", distinct=True))
        .order_by("email")
    )
    return render(
        request,
        "admin_panel/crm_org/account_managers_list.html",
        {"managers": rows, "page_title": "Account managers"},
    )


@_ADMIN
@require_http_methods(["GET", "POST"])
def account_manager_create(request):
    eligible = User.objects.filter(
        role__in=[User.Roles.CLIENT, User.Roles.TRADER, User.Roles.COPIER],
    ).order_by("email")[:800]
    if request.method == "POST":
        username = (request.POST.get("username") or "").strip()
        email = (request.POST.get("email") or "").strip().lower()
        password = request.POST.get("password") or ""
        first_name = (request.POST.get("first_name") or "").strip()
        last_name = (request.POST.get("last_name") or "").strip()
        is_active = request.POST.get("is_active") == "on"
        raw_ids = request.POST.getlist("client_ids")
        client_ids = []
        for x in raw_ids:
            if str(x).isdigit():
                client_ids.append(int(x))
        client_ids = list(dict.fromkeys(client_ids))
        if not username or not email or not password:
            messages.error(request, "Username, email, and password are required.")
        elif User.objects.filter(username__iexact=username).exists():
            messages.error(request, "That username is already taken.")
        elif User.objects.filter(email__iexact=email).exists():
            messages.error(request, "That email is already registered.")
        else:
            with transaction.atomic():
                u = User(
                    username=username,
                    email=email,
                    first_name=first_name,
                    last_name=last_name,
                    role=User.Roles.MANAGER,
                    is_active=is_active,
                    is_staff=False,
                    is_superuser=False,
                )
                u.set_password(password)
                u.save()
                pdata = _perm_from_post(request.POST)
                ManagerPortalPermission.objects.create(manager=u, **pdata)
                valid_clients = set(
                    User.objects.filter(
                        pk__in=client_ids,
                        role__in=[User.Roles.CLIENT, User.Roles.TRADER, User.Roles.COPIER],
                    ).values_list("id", flat=True)
                )
                for cid in valid_clients:
                    ManagerAssignedClient.objects.create(
                        manager=u,
                        client_id=cid,
                        assigned_by=request.user,
                    )
                ok, err = _save_manager_target_from_post(u, request.POST)
                if not ok:
                    messages.warning(request, f"Manager created but target not saved: {err}")
                else:
                    messages.success(request, "Account manager created.")
                return redirect("admin-account-managers")
    return render(
        request,
        "admin_panel/crm_org/account_manager_form.html",
        {
            "manager": None,
            "perm": None,
            "assigned_ids": [],
            "eligible_clients": eligible,
            "active_manager_target": None,
            "page_title": "Add account manager",
        },
    )


@_ADMIN
@require_http_methods(["GET", "POST"])
def account_manager_edit(request, pk: int):
    manager = get_object_or_404(User, pk=pk, role=User.Roles.MANAGER)
    perm = ManagerPortalPermission.objects.filter(manager=manager).first()
    assigned_ids = list(
        ManagerAssignedClient.objects.filter(manager=manager).values_list("client_id", flat=True)
    )
    eligible = User.objects.filter(
        role__in=[User.Roles.CLIENT, User.Roles.TRADER, User.Roles.COPIER],
    ).order_by("email")[:800]

    if request.method == "POST" and request.POST.get("clear_manager_target") == "1":
        ManagerTarget.objects.filter(manager=manager, is_active=True).update(is_active=False)
        messages.success(request, "Manager target cleared.")
        return redirect("admin-account-manager-edit", pk=manager.pk)

    if request.method == "POST":
        email = (request.POST.get("email") or "").strip().lower()
        first_name = (request.POST.get("first_name") or "").strip()
        last_name = (request.POST.get("last_name") or "").strip()
        is_active = request.POST.get("is_active") == "on"
        password = request.POST.get("password") or ""
        raw_ids = request.POST.getlist("client_ids")
        client_ids = []
        for x in raw_ids:
            if str(x).isdigit():
                client_ids.append(int(x))
        client_ids = list(dict.fromkeys(client_ids))
        if not email:
            messages.error(request, "Email is required.")
        elif User.objects.filter(email__iexact=email).exclude(pk=manager.pk).exists():
            messages.error(request, "That email is already used by another user.")
        else:
            with transaction.atomic():
                manager.email = email
                manager.first_name = first_name
                manager.last_name = last_name
                manager.is_active = is_active
                update_fields = ["email", "first_name", "last_name", "is_active"]
                if password:
                    manager.set_password(password)
                    update_fields.append("password")
                manager.save(update_fields=update_fields)
                pdata = _perm_from_post(request.POST)
                if perm:
                    for k, v in pdata.items():
                        setattr(perm, k, v)
                    perm.save()
                else:
                    ManagerPortalPermission.objects.create(manager=manager, **pdata)
                valid_clients = list(
                    User.objects.filter(
                        pk__in=client_ids,
                        role__in=[User.Roles.CLIENT, User.Roles.TRADER, User.Roles.COPIER],
                    ).values_list("id", flat=True)
                )
                ManagerAssignedClient.objects.filter(manager=manager).delete()
                for cid in valid_clients:
                    ManagerAssignedClient.objects.create(
                        manager=manager,
                        client_id=cid,
                        assigned_by=request.user,
                    )
                ok, err = _save_manager_target_from_post(manager, request.POST)
                if not ok:
                    messages.warning(request, f"Saved manager, but target error: {err}")
                else:
                    messages.success(request, "Account manager updated.")
                return redirect("admin-account-managers")

    return render(
        request,
        "admin_panel/crm_org/account_manager_form.html",
        {
            "manager": manager,
            "perm": perm,
            "assigned_ids": assigned_ids,
            "eligible_clients": eligible,
            "active_manager_target": _active_target_for_template(manager),
            "page_title": "Edit account manager",
        },
    )
