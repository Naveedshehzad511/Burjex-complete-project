try:
    from celery import shared_task
except ImportError:  # pragma: no cover — dev env without Celery installed

    def shared_task(*args, **kwargs):
        """Fallback so Django loads; .delay() runs the function synchronously."""

        def decorator(f):
            def delay(*a, **kw):
                return f(*a, **kw)

            f.delay = delay
            return f

        if args and callable(args[0]):
            return decorator(args[0])
        return decorator


@shared_task
def send_security_alert_email_task(user_id: int, subject: str, body: str) -> None:
    from accounts.models import User
    from admin_panel.email_service import send_dynamic_email

    user = User.objects.filter(id=user_id).first()
    if not user or not user.email:
        return
    send_dynamic_email(user.email, subject[:200], body, user=user)


@shared_task
def send_withdrawal_security_email_task(user_id: int, amount: str, currency: str) -> None:
    from accounts.models import User
    from admin_panel.email_service import send_dynamic_email

    user = User.objects.filter(id=user_id).first()
    if not user or not user.email:
        return
    send_dynamic_email(
        user.email,
        "Withdrawal confirmation",
        f"A withdrawal request was submitted for {amount} {currency}. If you did not initiate this, contact support immediately.",
        user=user,
    )


@shared_task
def notify_admins_risk_alert_task(message: str) -> None:
    from accounts.models import User
    from admin_panel.email_service import send_dynamic_email

    qs = User.objects.filter(
        role__in=[User.Roles.ADMIN, User.Roles.BANKER],
        is_active=True,
    ).exclude(email="")[:40]
    for u in qs:
        send_dynamic_email(u.email, "CRM risk alert", message[:2000], user=u)


@shared_task
def create_staff_notification_task(recipient_id: int, title: str, body: str) -> None:
    from accounts.models import User
    from .models import StaffNotification

    recipient = User.objects.filter(id=recipient_id).first()
    if recipient:
        StaffNotification.objects.create(recipient=recipient, title=title[:200], body=body[:5000])


@shared_task
def crm_backup_task() -> dict[str, str]:
    """Legacy daily backup task (kept for backward compatibility)."""
    from enterprise.services.data_protection import create_database_backup

    return create_database_backup(backup_type="daily").as_dict()


@shared_task
def crm_weekly_backup_task() -> dict[str, str]:
    """Weekly backup task for longer retention snapshots."""
    from enterprise.services.data_protection import create_database_backup

    return create_database_backup(backup_type="weekly").as_dict()


@shared_task
def crm_pre_update_backup_task() -> dict[str, str]:
    """Pre-update backup task to protect data before deployments."""
    from enterprise.services.data_protection import ensure_backup_before_update

    return ensure_backup_before_update().as_dict()
