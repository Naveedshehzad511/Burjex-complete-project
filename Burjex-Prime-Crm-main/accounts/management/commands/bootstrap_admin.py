"""Create / update the CRM admin from environment variables (runs on every crm-web start).

    CRM_ADMIN_EMAIL     (required, with the password)
    CRM_ADMIN_PASSWORD  (required, with the email)
    CRM_ADMIN_USERNAME  (optional; default: the part of the email before "@")

Idempotent: with no variables set it does nothing; with them set it creates the admin when missing and
otherwise makes the existing account match (password, active, verified, admin role). Changing the
password in the env and restarting therefore changes the admin's password. Changing the EMAIL creates a
second admin - the old one stays until you deactivate it in the CRM.
"""

import os

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Create or update the CRM admin account from CRM_ADMIN_EMAIL / CRM_ADMIN_PASSWORD."

    def handle(self, *args, **options):
        email = (os.environ.get("CRM_ADMIN_EMAIL") or "").strip().lower()
        password = os.environ.get("CRM_ADMIN_PASSWORD") or ""
        if not email and not password:
            self.stdout.write("bootstrap_admin: CRM_ADMIN_EMAIL / CRM_ADMIN_PASSWORD not set - nothing to do.")
            return
        if not email or not password:
            self.stdout.write(
                self.style.WARNING("bootstrap_admin: CRM_ADMIN_EMAIL and CRM_ADMIN_PASSWORD must both be set - skipped.")
            )
            return

        User = get_user_model()
        user = User.objects.filter(email__iexact=email).first()
        if user is None:
            username = (os.environ.get("CRM_ADMIN_USERNAME") or email.split("@")[0]).strip() or "admin"
            candidate, n = username, 1
            while User.objects.filter(username__iexact=candidate).exists():
                n += 1
                candidate = f"{username}{n}"
            user = User(username=candidate, email=email)
            created = True
        else:
            created = False

        changed = created
        if created or not user.check_password(password):
            user.set_password(password)
            changed = True
        wanted = {
            "is_active": True,
            "is_staff": True,
            "is_superuser": True,
            "role": User.Roles.ADMIN,
            "email_verified": True,
            "account_status": User.AccountStatus.APPROVED,
        }
        for field, value in wanted.items():
            if getattr(user, field) != value:
                setattr(user, field, value)
                changed = True

        if changed:
            user.save()
            self.stdout.write(self.style.SUCCESS(f"bootstrap_admin: {'created' if created else 'updated'} admin {email}"))
        else:
            self.stdout.write(f"bootstrap_admin: admin {email} already up to date")
