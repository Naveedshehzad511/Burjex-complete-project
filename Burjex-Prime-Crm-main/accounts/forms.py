from django import forms
from django.contrib.auth import authenticate
from django.contrib.auth.forms import AuthenticationForm
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError

from .models import User
from admin_panel.models import SignupSettings


class EmailOrUsernameAuthenticationForm(AuthenticationForm):
    """
    Allows logging in with either:
    - Email address (matched case-insensitively to User.email)
    - Username (the default AbstractUser username field)
    """

    def clean(self):
        username = self.cleaned_data.get("username")
        password = self.cleaned_data.get("password")

        # AuthenticationForm.clean() would authenticate directly with the entered value.
        # We override to translate email -> actual username when needed.
        email_candidate = username or ""
        login_username = email_candidate
        user_by_identifier = None

        if "@" in email_candidate:
            user_by_identifier = User.objects.filter(email__iexact=email_candidate).first()
            if user_by_identifier:
                login_username = user_by_identifier.get_username()
        else:
            user_by_identifier = User.objects.filter(username=email_candidate).first()

        self.user_cache = authenticate(self.request, username=login_username, password=password)
        if self.user_cache is None:
            # Inactive users fail authenticate(); give a clear message when credentials are valid.
            candidate = user_by_identifier or User.objects.filter(username=login_username).first()
            if candidate and password and candidate.check_password(password):
                from admin_panel.models import EmailVerificationSettings

                ev = EmailVerificationSettings.get_solo()
                if ev.enabled and not candidate.email_verified:
                    self.request.session["pending_verify_email"] = candidate.email
                    raise ValidationError(
                        "Please verify your email before login.",
                        code="unverified_email",
                    )
                if not candidate.is_active:
                    raise ValidationError("Your account is disabled.", code="inactive")
            raise ValidationError(self.error_messages["invalid_login"], code="invalid_login")

        self.confirm_login_allowed(self.user_cache)
        return self.cleaned_data


class ClientSignupForm(forms.Form):
    full_name = forms.CharField(max_length=150, required=False)
    first_name = forms.CharField(max_length=80, required=False)
    last_name = forms.CharField(max_length=80, required=False)
    email = forms.EmailField(required=False)
    phone = forms.CharField(max_length=40, required=False)
    country = forms.CharField(max_length=120, required=False)
    address = forms.CharField(max_length=255, required=False)
    password = forms.CharField(widget=forms.PasswordInput, required=False)
    confirm_password = forms.CharField(widget=forms.PasswordInput, required=False)
    captcha = forms.CharField(required=False)

    def __init__(self, *args, **kwargs):
        self.signup_settings = kwargs.pop("signup_settings")
        self.require_verification_email = bool(kwargs.pop("require_verification_email", False))
        super().__init__(*args, **kwargs)
        self.fields["country"].widget = forms.Select(choices=[("", "Select Country")])
        for name, field in self.fields.items():
            if isinstance(field.widget, forms.HiddenInput):
                continue
            field.widget.attrs["class"] = "form-control"
        ph = {
            "full_name": "Full name",
            "first_name": "First name",
            "last_name": "Last name",
            "email": "Email address",
            "phone": "Phone number",
            "country": "Country",
            "address": "Address",
            "password": "Create password",
            "confirm_password": "Re-enter password",
        }
        for fname, text in ph.items():
            if fname in self.fields and not isinstance(self.fields[fname].widget, forms.HiddenInput):
                self.fields[fname].widget.attrs.setdefault("placeholder", text)
        mode_map = {
            "full_name": self.signup_settings.full_name_mode,
            "first_name": self.signup_settings.first_name_mode,
            "last_name": self.signup_settings.last_name_mode,
            "email": self.signup_settings.email_mode,
            "phone": self.signup_settings.phone_mode,
            "country": self.signup_settings.country_mode,
            "address": self.signup_settings.address_mode,
            "password": self.signup_settings.password_mode,
        }
        for field, mode in mode_map.items():
            if mode == SignupSettings.FieldMode.HIDDEN:
                self.fields[field].widget = forms.HiddenInput()
                self.fields[field].required = False
            else:
                self.fields[field].required = mode == SignupSettings.FieldMode.REQUIRED
        self.fields["confirm_password"].required = self.fields["password"].required
        if not self.signup_settings.captcha_enabled:
            self.fields["captcha"].widget = forms.HiddenInput()
            self.fields["captcha"].required = False
        else:
            self.fields["captcha"].required = True

    def clean_email(self):
        email = (self.cleaned_data.get("email") or "").strip().lower()
        if email and User.objects.filter(email__iexact=email).exists():
            raise ValidationError("Email already registered.")
        return email

    def clean(self):
        cleaned = super().clean()
        if self.require_verification_email:
            if isinstance(self.fields["email"].widget, forms.HiddenInput):
                raise ValidationError("Email verification is on but the email field is hidden. Adjust signup field settings.")
            em = (cleaned.get("email") or "").strip()
            if not em:
                raise ValidationError("Email is required so we can send your verification link.")
        password = cleaned.get("password") or ""
        confirm_password = cleaned.get("confirm_password") or ""
        if self.fields["password"].required or password:
            if password != confirm_password:
                raise ValidationError("Password and confirm password do not match.")
            validate_password(password)
        if self.signup_settings.captcha_enabled:
            cap = (cleaned.get("captcha") or "").strip().lower()
            # The signup template renders captcha as a checkbox; a ticked checkbox
            # submits "on". Accept that alongside the legacy text-entry phrases.
            if cap not in {"on", "i am human", "i'm human", "human"}:
                raise ValidationError("Please tick the security check box to continue.")
        return cleaned


class SetNewPasswordForm(forms.Form):
    new_password = forms.CharField(
        min_length=8,
        widget=forms.PasswordInput(
            attrs={
                "class": "bp-input",
                "placeholder": "New password",
                "autocomplete": "new-password",
            }
        ),
    )
    confirm_password = forms.CharField(
        widget=forms.PasswordInput(
            attrs={
                "class": "bp-input",
                "placeholder": "Confirm new password",
                "autocomplete": "new-password",
            }
        ),
    )

    def clean(self):
        cleaned = super().clean()
        password = cleaned.get("new_password") or ""
        confirm = cleaned.get("confirm_password") or ""
        if password != confirm:
            raise ValidationError("Password and confirm password do not match.")
        validate_password(password)
        return cleaned


class ForgotPasswordForm(forms.Form):
    email = forms.EmailField()

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["email"].widget.attrs.update(
            {
                "class": "form-control",
                "placeholder": "Email address",
                "autocomplete": "email",
            }
        )

