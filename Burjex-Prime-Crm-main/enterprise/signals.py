from django.contrib.auth.signals import user_logged_in, user_login_failed
from django.core.cache import cache
from django.dispatch import receiver
from django.utils import timezone

from .models import EnterpriseSecuritySettings, LoginChannel, LoginEvent
from .audit import get_client_ip
from .risk import adjust_risk_score, flag_suspicious_ip_failures
from .tasks import send_security_alert_email_task


def _login_channel(request) -> str:
    path = (getattr(request, "path", "") or "").lower()
    if "/admin/login" in path:
        return LoginChannel.ADMIN
    return LoginChannel.CLIENT


def _ua_short(request) -> str:
    return (request.META.get("HTTP_USER_AGENT") or "")[:512]


@receiver(user_logged_in)
def on_user_logged_in(sender, request, user, **kwargs):
    if not request:
        return
    ip = get_client_ip(request)
    channel = _login_channel(request)
    ua = _ua_short(request)
    suspicious = False
    sec = EnterpriseSecuritySettings.get_solo()
    if ip:
        prev = (
            LoginEvent.objects.filter(user=user, success=True, channel=channel)
            .exclude(user_agent=ua)
            .order_by("-created_at")
            .first()
        )
        if prev and sec.login_new_device_alert and sec.email_security_alerts:
            suspicious = True
            from django.conf import settings

            # Eager Celery + broken SMTP must not block Flutter/API login in DEBUG.
            if not getattr(settings, "DEBUG", False):
                send_security_alert_email_task.delay(
                    user.id,
                    "Security alert: new sign-in",
                    f"A new sign-in to your account was detected from IP {ip}. If this was not you, change your password and contact support.",
                )
    LoginEvent.objects.create(
        user=user,
        username_attempt=user.username,
        success=True,
        channel=channel,
        ip=ip,
        user_agent=ua,
        suspicious=suspicious,
        notes="",
    )
    if ip:
        cache.delete(f"enterprise_login_fail_{ip}")


@receiver(user_login_failed)
def on_user_login_failed(sender, credentials, request, **kwargs):
    if not request:
        return
    ip = get_client_ip(request) or "unknown"
    channel = _login_channel(request)
    username = ""
    if isinstance(credentials, dict):
        username = (credentials.get("username") or credentials.get("email") or "")[:254]
    sec = EnterpriseSecuritySettings.get_solo()
    max_fails = sec.failed_login_max_attempts
    lock_seconds = sec.failed_login_lockout_seconds
    fail_key = f"enterprise_login_fail_{ip}"
    n = cache.get(fail_key, 0) + 1
    cache.set(fail_key, n, timeout=3600)
    if n >= max_fails:
        cache.set(f"enterprise_login_lock_{ip}", 1, timeout=lock_seconds)
    ev = LoginEvent.objects.create(
        user=None,
        username_attempt=username,
        success=False,
        channel=channel,
        ip=ip if ip != "unknown" else None,
        user_agent=_ua_short(request),
        suspicious=False,
        notes="Failed credentials",
    )
    suspicious = flag_suspicious_ip_failures(ip)
    if suspicious:
        ev.suspicious = True
        ev.save(update_fields=["suspicious"])
    if suspicious and sec.email_security_alerts:
        from django.conf import settings

        if not getattr(settings, "DEBUG", False):
            from accounts.models import User

            for admin in User.objects.filter(
                role__in=[User.Roles.ADMIN, User.Roles.BANKER],
                is_active=True,
            ).exclude(email="")[:20]:
                send_security_alert_email_task.delay(
                    admin.id,
                    "Suspicious login activity",
                    f"Multiple failed logins from IP {ip}.",
                )
    if username:
        from django.contrib.auth import get_user_model

        UserModel = get_user_model()
        u = UserModel.objects.filter(username__iexact=username).first() or UserModel.objects.filter(
            email__iexact=username
        ).first()
        if u and u.is_client():
            adjust_risk_score(u, 2, "Repeated failed login attempts")
