from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion
from django.utils import timezone


def seed_ticket_numbers(apps, schema_editor):
    SupportTicket = apps.get_model("live_chat", "SupportTicket")
    for t in SupportTicket.objects.filter(ticket_number=""):
        t.ticket_number = f"TKT-{timezone.now().strftime('%Y%m%d')}-{t.id}"
        t.save(update_fields=["ticket_number"])


class Migration(migrations.Migration):

    dependencies = [
        ("live_chat", "0001_initial"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="SupportTicket",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("subject", models.CharField(max_length=200)),
                ("description", models.TextField()),
                ("category", models.CharField(choices=[("ACCOUNT_RELATED", "Account Related"), ("BILLING_RELATED", "Billing Related"), ("GENERAL_INQUIRY", "General Inquiry"), ("PAYMENT_RELATED", "Payment Related"), ("TECHNICAL_SUPPORT", "Technical Support")], default="GENERAL_INQUIRY", max_length=30)),
                ("priority", models.CharField(choices=[("LOW", "Low"), ("MEDIUM", "Medium"), ("HIGH", "High"), ("URGENT", "Urgent")], default="MEDIUM", max_length=10)),
                ("status", models.CharField(choices=[("PENDING", "Pending"), ("OPEN", "Open"), ("IN_PROGRESS", "In Progress"), ("RESOLVED", "Resolved"), ("CLOSED", "Closed")], db_index=True, default="PENDING", max_length=20)),
                ("ticket_number", models.CharField(db_index=True, max_length=40, unique=True)),
                ("read_by_admin", models.BooleanField(default=False)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("resolved_at", models.DateTimeField(blank=True, null=True)),
                ("closed_at", models.DateTimeField(blank=True, null=True)),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="support_tickets", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["-updated_at", "-id"]},
        ),
        migrations.CreateModel(
            name="SupportTicketReply",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("is_admin", models.BooleanField(default=False)),
                ("message", models.TextField()),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("sender", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, to=settings.AUTH_USER_MODEL)),
                ("ticket", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="replies", to="live_chat.supportticket")),
            ],
            options={"ordering": ["id"]},
        ),
        migrations.RunPython(seed_ticket_numbers, migrations.RunPython.noop),
    ]
