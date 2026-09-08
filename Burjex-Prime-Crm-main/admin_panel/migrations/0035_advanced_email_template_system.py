from django.db import migrations, models
from django.utils.text import slugify


def populate_email_template_defaults(apps, schema_editor):
    EmailTemplate = apps.get_model("admin_panel", "EmailTemplate")
    for row in EmailTemplate.objects.all():
        if not getattr(row, "slug", None):
            raw = row.event_key or row.name or "template"
            base = (slugify(raw) or "template")[:120]
            candidate = base
            idx = 0
            while EmailTemplate.objects.exclude(pk=row.pk).filter(slug=candidate).exists():
                idx += 1
                candidate = f"{base[:110]}-{idx}"
            row.slug = candidate
        if not getattr(row, "category", None):
            row.category = "user"
        row.save(update_fields=["slug", "category"])


class Migration(migrations.Migration):
    """Idempotent SQL — avoids Django PG double-create of unique/_like indexes."""

    dependencies = [
        ("admin_panel", "0034_legaldocument_dynamic_system"),
    ]

    operations = [
        migrations.SeparateDatabaseAndState(
            state_operations=[
                migrations.RenameField(
                    model_name="emailtemplate",
                    old_name="body",
                    new_name="html_content",
                ),
                migrations.RenameField(
                    model_name="emailtemplate",
                    old_name="send_enabled",
                    new_name="is_active",
                ),
                migrations.AddField(
                    model_name="emailtemplate",
                    name="category",
                    field=models.CharField(
                        choices=[
                            ("user", "User Emails"),
                            ("admin", "Admin Emails"),
                            ("partner", "Partner Emails"),
                        ],
                        db_index=True,
                        default="user",
                        max_length=20,
                    ),
                ),
                migrations.AddField(
                    model_name="emailtemplate",
                    name="created_at",
                    field=models.DateTimeField(auto_now_add=True, null=True),
                    preserve_default=False,
                ),
                migrations.AddField(
                    model_name="emailtemplate",
                    name="slug",
                    field=models.SlugField(
                        blank=True, default="", max_length=140, unique=True
                    ),
                ),
                migrations.AlterField(
                    model_name="emailtemplate",
                    name="event_key",
                    field=models.CharField(
                        blank=True,
                        choices=[
                            ("account_created", "Account Created"),
                            ("email_verification", "Email Verification"),
                            ("email_verified", "Email Verified"),
                            ("forgot_password", "Forgot Password"),
                            ("kyc_approved", "KYC Approved"),
                            ("kyc_rejected", "KYC Rejected"),
                            ("kyc_submitted", "KYC Submitted"),
                            ("identity_submitted", "Identity Documents Submitted"),
                            ("identity_approved", "Identity Verification Approved"),
                            ("identity_rejected", "Identity Verification Rejected"),
                            ("address_submitted", "Address Documents Submitted"),
                            ("address_approved", "Address Verification Approved"),
                            ("address_rejected", "Address Verification Rejected"),
                            ("account_verified", "Account Fully Verified"),
                            ("withdrawal_approved", "Withdrawal Approved"),
                            ("withdrawal_rejected", "Withdrawal Rejected"),
                            ("withdrawal_submitted", "Withdrawal Submitted"),
                            ("deposit_approved", "Deposit Approved"),
                            ("deposit_rejected", "Deposit Rejected"),
                            ("deposit_submitted", "Deposit Submitted"),
                            ("ib_request_approved", "IB Request Approved"),
                            ("ib_request_rejected", "IB Request Rejected"),
                            ("signup_welcome", "Signup Welcome"),
                            ("password_reset", "Password Reset"),
                            ("account_approved", "Account Approved"),
                            ("real_account_created", "Real Account Created"),
                            ("demo_account_created", "Demo Account Created"),
                        ],
                        default="",
                        max_length=64,
                        unique=True,
                    ),
                ),
            ],
            database_operations=[
                migrations.RunSQL(
                    sql=r"""
                    DO $$
                    BEGIN
                      IF EXISTS (
                        SELECT 1 FROM information_schema.columns
                        WHERE table_name='admin_panel_emailtemplate' AND column_name='body'
                      ) THEN
                        ALTER TABLE admin_panel_emailtemplate RENAME COLUMN body TO html_content;
                      END IF;
                      IF EXISTS (
                        SELECT 1 FROM information_schema.columns
                        WHERE table_name='admin_panel_emailtemplate' AND column_name='send_enabled'
                      ) THEN
                        ALTER TABLE admin_panel_emailtemplate RENAME COLUMN send_enabled TO is_active;
                      END IF;
                    END $$;
                    ALTER TABLE admin_panel_emailtemplate ADD COLUMN IF NOT EXISTS category varchar(20) DEFAULT 'user' NOT NULL;
                    ALTER TABLE admin_panel_emailtemplate ADD COLUMN IF NOT EXISTS created_at timestamptz NULL;
                    ALTER TABLE admin_panel_emailtemplate ADD COLUMN IF NOT EXISTS slug varchar(140) DEFAULT '' NOT NULL;
                    CREATE INDEX IF NOT EXISTS admin_panel_emailtemplate_category_idx
                      ON admin_panel_emailtemplate (category);
                    -- event_key unique often already exists from older migrations; skip if present
                    """,
                    reverse_sql=migrations.RunSQL.noop,
                ),
            ],
        ),
        migrations.RunPython(populate_email_template_defaults, migrations.RunPython.noop),
        migrations.RunSQL(
            sql=r"""
            DO $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM pg_constraint WHERE conname = 'admin_panel_emailtemplate_slug_key'
              ) THEN
                ALTER TABLE admin_panel_emailtemplate
                  ADD CONSTRAINT admin_panel_emailtemplate_slug_key UNIQUE (slug);
              END IF;
            END $$;
            """,
            reverse_sql=migrations.RunSQL.noop,
        ),
    ]
