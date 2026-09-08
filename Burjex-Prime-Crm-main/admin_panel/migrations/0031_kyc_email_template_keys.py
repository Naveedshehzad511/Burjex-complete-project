from django.db import migrations


def seed_kyc_templates(apps, schema_editor):
    EmailTemplate = apps.get_model("admin_panel", "EmailTemplate")
    rows = [
        (
            "identity_submitted",
            "Identity Documents Submitted",
            "Identity Documents Submitted",
            "Dear {{name}},\n\nWe received your identity documents and they are under review.\n\nUpload / status page:\n{{verify_url}}\n\nRegards,\n{{company_name}}",
        ),
        (
            "address_submitted",
            "Address Documents Submitted",
            "Address Documents Submitted",
            "Dear {{name}},\n\nWe received your address documents and they are under review.\n\nUpload / status page:\n{{verify_url}}\n\nRegards,\n{{company_name}}",
        ),
        (
            "account_verified",
            "Account Fully Verified",
            "Account Fully Verified",
            "Dear {{name}},\n\nYour account is fully verified (identity and address).\n\nClient area:\n{{verify_url}}\n\nRegards,\n{{company_name}}",
        ),
    ]
    for key, name, subj, body in rows:
        EmailTemplate.objects.get_or_create(
            event_key=key,
            defaults={"name": name, "subject": subj, "body": body, "send_enabled": True},
        )


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0030_remove_tradingaccounttype_demo_enabled_and_more"),
    ]

    operations = [
        migrations.RunPython(seed_kyc_templates, migrations.RunPython.noop),
    ]
