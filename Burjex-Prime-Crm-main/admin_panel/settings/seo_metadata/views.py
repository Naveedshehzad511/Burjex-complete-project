from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required

from .forms import SeoMetadataForm


@login_required
@role_required([User.Roles.ADMIN, User.Roles.BANKER])
@require_http_methods(["GET", "POST"])
def seo_metadata_settings(request):
    if request.method == "POST":
        form = SeoMetadataForm(request.POST)
        if form.is_valid():
            messages.success(request, "SEO metadata settings saved.")
            return redirect("admin-settings-seo-metadata")
        messages.error(request, "Please fix SEO metadata form errors.")
    else:
        form = SeoMetadataForm()
    return render(request, "settings/seo_metadata/index.html", {"form": form})

