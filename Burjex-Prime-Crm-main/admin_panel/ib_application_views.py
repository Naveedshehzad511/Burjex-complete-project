from django import forms
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import get_object_or_404, redirect, render
from django.views.decorators.http import require_http_methods

from accounts.models import User
from accounts.permissions import role_required
from ib.models import IBApplicationQuestion

ADMIN_IB_FORM_ROLES = [User.Roles.ADMIN, User.Roles.BANKER]


class IBApplicationQuestionForm(forms.ModelForm):
    class Meta:
        model = IBApplicationQuestion
        fields = ["sort_order", "label", "input_type", "choices", "required", "is_active"]
        widgets = {
            "sort_order": forms.NumberInput(attrs={"class": "border rounded px-3 py-2 text-sm w-32"}),
            "label": forms.TextInput(attrs={"class": "border rounded px-3 py-2 text-sm w-full max-w-xl"}),
            "input_type": forms.Select(attrs={"class": "border rounded px-3 py-2 text-sm w-full max-w-md"}),
            "choices": forms.Textarea(attrs={"rows": 5, "class": "border rounded px-3 py-2 text-sm w-full max-w-xl font-mono text-xs"}),
            "required": forms.CheckboxInput(attrs={"class": "rounded"}),
            "is_active": forms.CheckboxInput(attrs={"class": "rounded"}),
        }

    def clean(self):
        data = super().clean()
        it = data.get("input_type")
        ch = (data.get("choices") or "").strip()
        if it in (IBApplicationQuestion.InputType.SELECT, IBApplicationQuestion.InputType.MULTI) and not ch:
            self.add_error("choices", "Add at least one option (one per line) for this field type.")
        return data


@login_required
@role_required(ADMIN_IB_FORM_ROLES)
def ib_application_form_settings(request):
    questions = IBApplicationQuestion.objects.order_by("sort_order", "id")
    return render(
        request,
        "admin_panel/ib_application_form_settings.html",
        {"questions": questions},
    )


@login_required
@role_required(ADMIN_IB_FORM_ROLES)
@require_http_methods(["GET", "POST"])
def ib_application_question_add(request):
    if request.method == "POST":
        form = IBApplicationQuestionForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, "Question added.")
            return redirect("admin-ib-application-form")
    else:
        form = IBApplicationQuestionForm()
    return render(request, "admin_panel/ib_application_question_form.html", {"form": form, "question": None})


@login_required
@role_required(ADMIN_IB_FORM_ROLES)
@require_http_methods(["GET", "POST"])
def ib_application_question_edit(request, pk: int):
    obj = get_object_or_404(IBApplicationQuestion, pk=pk)
    if request.method == "POST":
        form = IBApplicationQuestionForm(request.POST, instance=obj)
        if form.is_valid():
            form.save()
            messages.success(request, "Question updated.")
            return redirect("admin-ib-application-form")
    else:
        form = IBApplicationQuestionForm(instance=obj)
    return render(request, "admin_panel/ib_application_question_form.html", {"form": form, "question": obj})


@login_required
@role_required(ADMIN_IB_FORM_ROLES)
@require_http_methods(["POST"])
def ib_application_question_delete(request, pk: int):
    get_object_or_404(IBApplicationQuestion, pk=pk).delete()
    messages.success(request, "Question removed.")
    return redirect("admin-ib-application-form")
