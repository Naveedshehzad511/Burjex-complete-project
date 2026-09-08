from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.http import JsonResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .models import Tag, TagCategory, UserTag


TAG_CATEGORY_DEFAULTS = {
    TagCategory.Type.CLIENT: "Client Tags",
}


def _ensure_tag_categories():
    for key, name in TAG_CATEGORY_DEFAULTS.items():
        TagCategory.objects.get_or_create(type=key, defaults={"name": name})


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def tag_system(request):
    _ensure_tag_categories()
    if request.method == "POST":
        action = (request.POST.get("action") or "").strip()
        category_type = (request.POST.get("category_type") or "").strip()
        category = TagCategory.objects.filter(type=category_type).first()
        if action == "create_tag":
            if not category:
                messages.error(request, "Select a valid category.")
                return redirect("admin-tag-system")
            name = (request.POST.get("name") or "").strip()
            color = (request.POST.get("color") or "#64748b").strip()
            description = (request.POST.get("description") or "").strip()
            if not name:
                messages.error(request, "Tag name is required.")
                return redirect("admin-tag-system")
            Tag.objects.get_or_create(
                category=category,
                name=name,
                defaults={"description": description, "color": color, "is_active": True},
            )
            messages.success(request, "Tag created.")
            return redirect(f"{request.path}?tab={category.type}")
        if action == "edit_tag":
            tag_id = request.POST.get("tag_id") or ""
            tag = Tag.objects.filter(id=tag_id).select_related("category").first()
            if not tag:
                messages.error(request, "Tag not found.")
                return redirect("admin-tag-system")
            name = (request.POST.get("name") or "").strip()
            if not name:
                messages.error(request, "Tag name is required.")
                return redirect(f"{request.path}?tab={tag.category.type}")
            tag.name = name
            tag.description = (request.POST.get("description") or "").strip()
            tag.color = (request.POST.get("color") or tag.color).strip()
            tag.save(update_fields=["name", "description", "color", "updated_at"])
            messages.success(request, "Tag updated.")
            return redirect(f"{request.path}?tab={tag.category.type}")
        if action == "delete_tag":
            tag_id = request.POST.get("tag_id") or ""
            tag = Tag.objects.filter(id=tag_id).select_related("category").first()
            if not tag:
                messages.error(request, "Tag not found.")
                return redirect("admin-tag-system")
            tab = tag.category.type
            tag.delete()
            messages.success(request, "Tag deleted.")
            return redirect(f"{request.path}?tab={tab}")
        if action == "toggle_tag":
            tag_id = request.POST.get("tag_id") or ""
            tag = Tag.objects.filter(id=tag_id).select_related("category").first()
            if not tag:
                messages.error(request, "Tag not found.")
                return redirect("admin-tag-system")
            tag.is_active = not tag.is_active
            tag.save(update_fields=["is_active", "updated_at"])
            messages.success(request, f"Tag {'enabled' if tag.is_active else 'disabled'}.")
            return redirect(f"{request.path}?tab={tag.category.type}")
    categories = list(TagCategory.objects.order_by("name"))
    active_tab = TagCategory.Type.CLIENT
    tags_by_type = {
        c.type: list(c.tags.order_by("name"))
        for c in categories
    }
    active_tags = tags_by_type.get(active_tab, [])
    tagged_clients = UserTag.objects.filter(tag__category__type=TagCategory.Type.CLIENT).select_related('user', 'tag').order_by('-id')

    return render(
        request,
        "admin_panel/tag_system.html",
        {
            "title": "Tag System",
            "active_tags": active_tags,
            "tagged_clients": tagged_clients,
        },
    )


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def user_tag_assign(request, pk: int):
    user = get_object_or_404(User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]), pk=pk)
    tag_id = request.POST.get("tag_id") or ""
    notes = (request.POST.get("notes") or "").strip()
    tag = get_object_or_404(Tag.objects.filter(is_active=True), pk=tag_id)
    obj, created = UserTag.objects.get_or_create(
        user=user,
        tag=tag,
        defaults={"assigned_by": request.user, "notes": notes},
    )
    if not created and notes:
        obj.notes = notes
        obj.assigned_by = request.user
        obj.save(update_fields=["notes", "assigned_by"])
    payload = {
        "ok": True,
        "created": created,
        "user_tag_id": obj.id,
        "tag_id": tag.id,
        "name": tag.name,
        "color": tag.color,
        "notes": obj.notes,
        "category": tag.category.name,
    }
    return JsonResponse(payload)


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["POST"])
def user_tag_remove(request, pk: int, user_tag_id: int):
    user = get_object_or_404(User.objects.exclude(role__in=[User.Roles.ADMIN, User.Roles.BANKER]), pk=pk)
    user_tag = get_object_or_404(UserTag.objects.select_related("user"), id=user_tag_id, user=user)
    user_tag.delete()
    return JsonResponse({"ok": True, "removed": True})
