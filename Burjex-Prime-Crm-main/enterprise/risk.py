from datetime import timedelta

from django.utils import timezone

from .models import ClientRiskProfile, EnterpriseSecuritySettings, LoginEvent, RiskAlert
from .tasks import notify_admins_risk_alert_task


def get_or_create_risk_profile(user):
    profile, _ = ClientRiskProfile.objects.get_or_create(user=user)
    return profile


def adjust_risk_score(user, delta: int, reason: str = "") -> None:
    if not user or not getattr(user, "pk", None):
        return
    profile = get_or_create_risk_profile(user)
    new_score = max(0, min(100, int(profile.risk_score or 0) + int(delta)))
    profile.risk_score = new_score
    profile.last_assessed_at = timezone.now()
    profile.save(update_fields=["risk_score", "last_assessed_at"])
    threshold = EnterpriseSecuritySettings.get_solo().risk_alert_threshold
    if new_score >= threshold:
        since = timezone.now() - timedelta(hours=6)
        if not RiskAlert.objects.filter(user=user, created_at__gte=since, level="HIGH").exists():
            RiskAlert.objects.create(
                user=user,
                level="HIGH",
                message=(reason[:500] if reason else f"Risk score reached {new_score}"),
            )
            notify_admins_risk_alert_task.delay(
                f"Client {user.email}: risk score {new_score}. {reason}"
            )


def flag_suspicious_ip_failures(ip: str) -> bool:
    if not ip:
        return False
    threshold = EnterpriseSecuritySettings.get_solo().suspicious_failures_per_ip
    since = timezone.now() - timedelta(hours=24)
    fail_count = LoginEvent.objects.filter(ip=ip, success=False, created_at__gte=since).count()
    return fail_count >= threshold
