"""CRM departments, sales managers, roles, and granular permission grants (admin/banker only)."""
from __future__ import annotations

import json
import re
from datetime import date
from decimal import Decimal

from django.contrib import messages
from django.db import transaction
from django.db.models import Count, Q
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.views.decorators.http import require_http_methods

from accounts.crm_permissions import ALL_PERMISSION_CODES, PERMISSION_LABELS, permission_codes_grouped_by_folder
from accounts.models import User
from accounts.permissions import role_required

from .models import (
    CrmDepartment,
    CrmPermissionGrant,
    CrmRole,
    CrmRoleGrant,
    CrmStaffProfile,
    ManagerClient,
    ManagerTarget,
)


def _admin_only(view_func):
    return role_required([User.Roles.ADMIN, User.Roles.BANKER])(view_func)


def _save_manager_target_from_post(manager: User, post) -> tuple[bool, str]:
    """
    Persist active ManagerTarget from admin form. Returns (success, error_message).
    """
    action = (post.get("manager_target_action") or "").strip()
    if action == "clear":
        ManagerTarget.objects.filter(manager=manager, is_active=True).update(is_active=False)
        return True, ""
    enabled = post.get("manager_target_enabled") == "on"
    if not enabled:
        ManagerTarget.objects.filter(manager=manager, is_active=True).update(is_active=False)
        return True, ""
    ttype = (post.get("manager_target_type") or "deposit").strip().lower()
    if ttype not in ("deposit", "volume"):
        ttype = "deposit"
    try:
        val = Decimal(str((post.get("manager_target_value") or "0").strip() or "0"))
    except Exception:
        return False, "Invalid target value."
    if val <= 0:
        return False, "Target value must be greater than zero."
    period = (post.get("manager_target_period") or ManagerTarget.Period.MONTHLY).strip().lower()
    if period not in (
        ManagerTarget.Period.MONTHLY,
        ManagerTarget.Period.WEEKLY,
        ManagerTarget.Period.DAILY,
    ):
        period = ManagerTarget.Period.MONTHLY
    start_d = None
    end_d = None
    if post.get("manager_target_custom_range") == "on":
        sd = (post.get("manager_target_start") or "").strip()
        ed = (post.get("manager_target_end") or "").strip()
        if sd and ed:
            try:
                start_d = date.fromisoformat(sd)
                end_d = date.fromisoformat(ed)
                if end_d < start_d:
                    return False, "Target end date must be on or after start date."
            except ValueError:
                return False, "Invalid custom date range."
    ManagerTarget.objects.filter(manager=manager, is_active=True).update(is_active=False)
    ManagerTarget.objects.create(
        manager=manager,
        target_type=ttype,
        target_value=val,
        period=period,
        start_date=start_d,
        end_date=end_d,
        is_active=True,
    )
    return True, ""


def _active_target_for_template(manager: User) -> ManagerTarget | None:
    return (
        ManagerTarget.objects.filter(manager=manager, is_active=True).order_by("-created_at").first()
    )


@_admin_only
@require_http_methods(["GET"])
def crm_departments_list(request):
    rows = CrmDepartment.objects.order_by("name").annotate(
        assigned_managers_count=Count("staff_users", distinct=True)
    )
    return render(
        request,
        "admin_panel/crm_org/departments_list.html",
        {"departments": rows, "page_title": "CRM departments"},
    )


@_admin_only
@require_http_methods(["GET", "POST"])
def crm_department_edit(request, pk: int | None = None):
    dept = get_object_or_404(CrmDepartment, pk=pk) if pk else None
    if request.method == "POST":
        name = (request.POST.get("name") or "").strip()
        slug = (request.POST.get("slug") or "").strip().lower()
        slug = re.sub(r"[^a-z0-9-]+", "-", slug).strip("-")[:64]
        description = (request.POST.get("description") or "").strip()
        is_active = request.POST.get("is_active") == "on"
        if not name or not slug:
            messages.error(request, "Name and slug are required.")
        else:
            if dept is None:
                if CrmDepartment.objects.filter(slug=slug).exists():
                    messages.error(request, "That slug is already in use.")
                else:
                    CrmDepartment.objects.create(
                        name=name, slug=slug, description=description, is_active=is_active
                    )
                    messages.success(request, "Department created.")
                    return redirect("admin-crm-departments")
            else:
                clash = CrmDepartment.objects.filter(slug=slug).exclude(pk=dept.pk).exists()
                if clash:
                    messages.error(request, "That slug is already in use.")
                else:
                    dept.name = name
                    dept.slug = slug
                    dept.description = description
                    dept.is_active = is_active
                    dept.save()
                    messages.success(request, "Department updated.")
                    return redirect("admin-crm-departments")
    return render(
        request,
        "admin_panel/crm_org/department_form.html",
        {"department": dept, "page_title": "Edit department" if dept else "Add department"},
    )


@_admin_only
@require_http_methods(["GET"])
def crm_sales_managers_list(request):
    managers = (
        User.objects.filter(role=User.Roles.SALES_MANAGER)
        .select_related("crm_department", "crm_staff_profile", "crm_role")
        .annotate(assigned_clients_count=Count("assigned_manager_clients", distinct=True))
        .order_by("email")
    )
    return render(
        request,
        "admin_panel/crm_org/sales_managers_list.html",
        {"managers": managers, "page_title": "Sales managers"},
    )


@_admin_only
@require_http_methods(["GET"])
def crm_sales_manager_assign_clients_candidates(request, pk: int):
    manager = get_object_or_404(User, pk=pk, role=User.Roles.SALES_MANAGER)
    q = (request.GET.get("q") or "").strip()
    qs = User.objects.filter(role=User.Roles.CLIENT).order_by("email", "id")
    if q:
        qs = qs.filter(
            Q(email__icontains=q)
            | Q(first_name__icontains=q)
            | Q(last_name__icontains=q)
        )
    assigned_ids = set(
        ManagerClient.objects.filter(manager=manager).values_list("client_id", flat=True)
    )
    clients_out = []
    for c in qs[:250]:
        assigned = c.pk in assigned_ids or c.registered_via_sales_manager_id == manager.pk
        name = f"{c.first_name} {c.last_name}".strip() or (c.email or str(c.pk))
        clients_out.append(
            {
                "id": c.pk,
                "name": name,
                "email": c.email,
                "phone": c.phone or "",
                "assigned": assigned,
            }
        )
    return JsonResponse({"clients": clients_out})


@_admin_only
@require_http_methods(["POST"])
def crm_sales_manager_assign_clients_submit(request, pk: int):
    manager = get_object_or_404(User, pk=pk, role=User.Roles.SALES_MANAGER)
    try:
        body = json.loads(request.body.decode() or "{}")
    except json.JSONDecodeError:
        return JsonResponse({"ok": False, "error": "Invalid JSON"}, status=400)
    raw_ids = body.get("client_ids")
    if not isinstance(raw_ids, list) or not raw_ids:
        return JsonResponse({"ok": False, "error": "Select at least one client."}, status=400)
    ids: list[int] = []
    for x in raw_ids:
        if isinstance(x, int) and x > 0:
            ids.append(x)
        elif isinstance(x, str) and x.isdigit():
            ids.append(int(x))
    ids = list(dict.fromkeys(ids))
    if not ids:
        return JsonResponse({"ok": False, "error": "Invalid client selection."}, status=400)

    clients = list(User.objects.filter(pk__in=ids, role=User.Roles.CLIENT))
    if len(clients) != len(ids):
        return JsonResponse(
            {"ok": False, "error": "One or more selected users are not valid clients."},
            status=400,
        )

    with transaction.atomic():
        for c in clients:
            ManagerClient.objects.filter(client=c).exclude(manager=manager).delete()
            mc, created = ManagerClient.objects.get_or_create(
                manager=manager,
                client=c,
                defaults={"assigned_by": request.user},
            )
            if not created:
                mc.assigned_by = request.user
                mc.save(update_fields=["assigned_by"])
            c.registered_via_sales_manager = manager
            c.save(update_fields=["registered_via_sales_manager"])

    count = ManagerClient.objects.filter(manager=manager).count()
    return JsonResponse(
        {
            "ok": True,
            "message": "Clients assigned successfully",
            "assigned_clients_count": count,
        }
    )


def _parse_role_id(post) -> int | None:
    raw = (post.get("crm_role_id") or "").strip()
    if not raw.isdigit():
        return None
    rid = int(raw)
    return rid if CrmRole.objects.filter(pk=rid).exists() else None


@_admin_only
@require_http_methods(["GET", "POST"])
def crm_sales_manager_create(request):
    departments = CrmDepartment.objects.filter(is_active=True).order_by("name")
    roles = CrmRole.objects.order_by("name")
    eligible_clients = User.objects.filter(role=User.Roles.CLIENT).order_by("email")
    if request.method == "POST":
        selected_client_id = (request.POST.get("client_user_id") or "").strip()
        selected_client = (
            User.objects.filter(pk=int(selected_client_id), role=User.Roles.CLIENT).first()
            if selected_client_id.isdigit()
            else None
        )
        username = (request.POST.get("username") or "").strip()
        password = request.POST.get("password") or ""
        referral_slug = (request.POST.get("referral_slug") or "").strip().lower()
        referral_slug = re.sub(r"[^a-z0-9-]+", "-", referral_slug).strip("-")[:80]
        dept_id = request.POST.get("department_id")
        is_active = request.POST.get("is_active") == "on"
        first_name = (request.POST.get("first_name") or "").strip()
        last_name = (request.POST.get("last_name") or "").strip()
        role_id = _parse_role_id(request.POST)
        if not selected_client:
            messages.error(request, "Please select an existing client email.")
        elif not password or not referral_slug:
            messages.error(request, "Password and referral slug are required.")
        elif CrmStaffProfile.objects.filter(referral_slug__iexact=referral_slug).exists():
            messages.error(request, "That referral slug is already used.")
        else:
            if not username:
                base = (selected_client.email.split("@")[0] or f"manager{selected_client.id}").lower()
                base = re.sub(r"[^a-z0-9_]+", "_", base).strip("_")[:100] or f"manager{selected_client.id}"
                username = base
                n = 1
                while User.objects.filter(username__iexact=username).exclude(pk=selected_client.pk).exists():
                    n += 1
                    username = f"{base}_{n}"
            if User.objects.filter(username__iexact=username).exclude(pk=selected_client.pk).exists():
                messages.error(request, "That username is taken.")
                return render(
                    request,
                    "admin_panel/crm_org/sales_manager_form.html",
                    {
                        "departments": departments,
                        "crm_roles": roles,
                        "manager_user": None,
                        "eligible_clients": eligible_clients,
                        "active_manager_target": None,
                        "page_title": "Create sales manager",
                    },
                )
            try:
                with transaction.atomic():
                    selected_client.username = username
                    selected_client.first_name = first_name or selected_client.first_name
                    selected_client.last_name = last_name or selected_client.last_name
                    selected_client.role = User.Roles.SALES_MANAGER
                    selected_client.is_staff = True
                    selected_client.is_active = is_active
                    selected_client.set_password(password)
                    if dept_id:
                        d = CrmDepartment.objects.filter(pk=int(dept_id), is_active=True).first()
                        selected_client.crm_department_id = d.id if d else None
                    else:
                        selected_client.crm_department_id = None
                    selected_client.crm_role_id = role_id
                    selected_client.save()
                    CrmStaffProfile.objects.update_or_create(
                        user=selected_client,
                        defaults={"referral_slug": referral_slug},
                    )
                ok_tgt, err_tgt = _save_manager_target_from_post(selected_client, request.POST)
                if ok_tgt:
                    messages.success(
                        request,
                        f"Sales manager created from existing client {selected_client.email}.",
                    )
                else:
                    messages.warning(
                        request,
                        f"Manager created, but target was not saved: {err_tgt}",
                    )
                return redirect("admin-crm-sales-managers")
            except Exception as exc:
                messages.error(request, f"Could not create manager: {exc}")
    return render(
        request,
        "admin_panel/crm_org/sales_manager_form.html",
        {
            "departments": departments,
            "crm_roles": roles,
            "manager_user": None,
            "eligible_clients": eligible_clients,
            "active_manager_target": None,
            "page_title": "Create sales manager",
        },
    )


@_admin_only
@require_http_methods(["GET", "POST"])
def crm_sales_manager_edit(request, pk: int):
    u = get_object_or_404(User, pk=pk, role=User.Roles.SALES_MANAGER)
    prof = getattr(u, "crm_staff_profile", None)
    departments = CrmDepartment.objects.filter(is_active=True).order_by("name")
    roles = CrmRole.objects.order_by("name")
    if request.method == "POST" and request.POST.get("clear_manager_target") == "1":
        ManagerTarget.objects.filter(manager=u, is_active=True).update(is_active=False)
        messages.success(request, "Manager target cleared.")
        return redirect("admin-crm-sales-manager-edit", pk=u.pk)
    if request.method == "POST":
        first_name = (request.POST.get("first_name") or "").strip()
        last_name = (request.POST.get("last_name") or "").strip()
        username = (request.POST.get("username") or "").strip()
        referral_slug = (request.POST.get("referral_slug") or "").strip().lower()
        referral_slug = re.sub(r"[^a-z0-9-]+", "-", referral_slug).strip("-")[:80]
        new_password = (request.POST.get("new_password") or "").strip()
        is_active = request.POST.get("is_active") == "on"
        dept_raw = (request.POST.get("department_id") or "").strip()
        role_id = _parse_role_id(request.POST)
        if not username or not referral_slug:
            messages.error(request, "Username and referral slug are required.")
        elif User.objects.filter(username__iexact=username).exclude(pk=u.pk).exists():
            messages.error(request, "That username is already in use.")
        elif (
            CrmStaffProfile.objects.filter(referral_slug__iexact=referral_slug)
            .exclude(user_id=u.pk)
            .exists()
        ):
            messages.error(request, "That referral slug is already used.")
        else:
            u.first_name = first_name
            u.last_name = last_name
            u.username = username
            u.is_active = is_active
            u.crm_role_id = role_id
            u.crm_department_id = int(dept_raw) if dept_raw.isdigit() else None
            fields = [
                "first_name",
                "last_name",
                "username",
                "is_active",
                "crm_role_id",
                "crm_department_id",
            ]
            if new_password:
                u.set_password(new_password)
                fields.append("password")
            u.save(update_fields=fields)
            if prof:
                prof.referral_slug = referral_slug
                prof.save(update_fields=["referral_slug"])
            else:
                CrmStaffProfile.objects.create(user=u, referral_slug=referral_slug)
            ok_tgt, err_tgt = _save_manager_target_from_post(u, request.POST)
            if ok_tgt:
                messages.success(request, "Sales manager updated.")
            else:
                messages.warning(request, f"Profile saved, but target: {err_tgt}")
            return redirect("admin-crm-sales-managers")
    return render(
        request,
        "admin_panel/crm_org/sales_manager_form.html",
        {
            "departments": departments,
            "crm_roles": roles,
            "manager_user": u,
            "active_manager_target": _active_target_for_template(u),
            "page_title": f"Edit sales manager — {u.email}",
        },
    )


@_admin_only
@require_http_methods(["GET"])
def crm_roles_list(request):
    roles = CrmRole.objects.order_by("name")
    return render(
        request,
        "admin_panel/crm_org/crm_roles_list.html",
        {"roles": roles, "page_title": "CRM roles"},
    )


@_admin_only
@require_http_methods(["GET", "POST"])
def crm_role_create(request):
    if request.method == "POST":
        name = (request.POST.get("name") or "").strip()
        slug = (request.POST.get("slug") or "").strip().lower()
        slug = re.sub(r"[^a-z0-9-]+", "-", slug).strip("-")[:64]
        description = (request.POST.get("description") or "").strip()
        if not name or not slug:
            messages.error(request, "Name and slug are required.")
        elif CrmRole.objects.filter(slug=slug).exists():
            messages.error(request, "That slug is already in use.")
        else:
            CrmRole.objects.create(name=name, slug=slug, description=description, is_system=False)
            messages.success(request, "Role created. Set permissions on the next screen.")
            r = CrmRole.objects.get(slug=slug)
            return redirect("admin-crm-role-permissions", pk=r.pk)
    return render(request, "admin_panel/crm_org/crm_role_form.html", {"page_title": "Create CRM role"})


@_admin_only
@require_http_methods(["POST"])
def crm_role_delete(request, pk: int):
    role = get_object_or_404(CrmRole, pk=pk)
    if role.is_system:
        messages.error(request, "System roles cannot be deleted.")
    else:
        role_name = role.name
        role.delete()
        messages.success(request, f"Role '{role_name}' deleted.")
    return redirect("admin-crm-roles")


@_admin_only
@require_http_methods(["GET", "POST"])
def crm_role_edit_grants(request, pk: int):
    role = get_object_or_404(CrmRole, pk=pk)
    perm_folders = permission_codes_grouped_by_folder()
    if request.method == "POST":
        with transaction.atomic():
            CrmRoleGrant.objects.filter(role=role).delete()
            to_create = []
            for code in ALL_PERMISSION_CODES:
                if request.POST.get(f"perm_{code}") == "on":
                    to_create.append(CrmRoleGrant(role=role, permission_code=code, granted=True))
            if to_create:
                CrmRoleGrant.objects.bulk_create(to_create, batch_size=300)
        messages.success(request, f"Permissions updated for “{role.name}”.")
        return redirect("admin-crm-role-permissions", pk=role.pk)

    granted = {g.permission_code for g in CrmRoleGrant.objects.filter(role=role, granted=True)}
    return render(
        request,
        "admin_panel/crm_org/crm_role_grants.html",
        {
            "role": role,
            "perm_folders": perm_folders,
            "granted_set": granted,
            "page_title": f"Role permissions — {role.name}",
        },
    )


@_admin_only
@require_http_methods(["GET", "POST"])
def crm_permissions_hub(request):
    departments = CrmDepartment.objects.filter(is_active=True).order_by("name")
    staff_users = (
        User.objects.filter(role=User.Roles.SALES_MANAGER, is_active=True)
        .select_related("crm_department", "crm_role")
        .order_by("email")
    )
    roles = CrmRole.objects.order_by("name")
    perms = [(c, PERMISSION_LABELS.get(c, ("Other", c))) for c in ALL_PERMISSION_CODES]
    perm_folders = permission_codes_grouped_by_folder()

    if request.method == "POST":
        target = (request.POST.get("target") or "").strip()
        tid = request.POST.get("target_id")
        code = (request.POST.get("permission_code") or "").strip()
        granted = request.POST.get("granted") == "on"
        if (
            target not in {"department", "user", "role"}
            or not tid
            or not str(tid).isdigit()
            or code not in ALL_PERMISSION_CODES
        ):
            messages.error(request, "Invalid permission form.")
        else:
            tid_int = int(tid)
            if target == "department":
                row = CrmPermissionGrant.objects.filter(
                    department_id=tid_int, user__isnull=True, permission_code=code
                ).first()
                if row:
                    row.granted = granted
                    row.save(update_fields=["granted"])
                else:
                    CrmPermissionGrant.objects.create(
                        department_id=tid_int, permission_code=code, granted=granted, user=None
                    )
            elif target == "user":
                row = CrmPermissionGrant.objects.filter(
                    user_id=tid_int, department__isnull=True, permission_code=code
                ).first()
                if row:
                    row.granted = granted
                    row.save(update_fields=["granted"])
                else:
                    CrmPermissionGrant.objects.create(
                        user_id=tid_int, permission_code=code, granted=granted, department=None
                    )
            else:
                row = CrmRoleGrant.objects.filter(role_id=tid_int, permission_code=code).first()
                if row:
                    row.granted = granted
                    row.save(update_fields=["granted"])
                else:
                    CrmRoleGrant.objects.create(role_id=tid_int, permission_code=code, granted=granted)
            messages.success(request, "Permission saved.")
        return redirect("admin-crm-permissions")

    dept_grants = {}
    for g in CrmPermissionGrant.objects.filter(department__isnull=False).select_related("department"):
        dept_grants.setdefault(g.department_id, {})[g.permission_code] = g.granted
    user_grants = {}
    for g in CrmPermissionGrant.objects.filter(user__isnull=False):
        user_grants.setdefault(g.user_id, {})[g.permission_code] = g.granted
    role_grants = {}
    for g in CrmRoleGrant.objects.select_related("role"):
        role_grants.setdefault(g.role_id, {})[g.permission_code] = g.granted

    return render(
        request,
        "admin_panel/crm_org/permissions_hub.html",
        {
            "departments": departments,
            "staff_users": staff_users,
            "crm_roles": roles,
            "perms": perms,
            "perm_folders": perm_folders,
            "dept_grants": dept_grants,
            "user_grants": user_grants,
            "role_grants": role_grants,
            "page_title": "CRM permissions",
        },
    )
