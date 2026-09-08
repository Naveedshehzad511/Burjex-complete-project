# Generated manually for IB application form

from django.db import migrations, models


def seed_default_ib_questions(apps, schema_editor):
    IBApplicationQuestion = apps.get_model("ib", "IBApplicationQuestion")
    defaults = [
        (10, "Do you have IB Experience?", "YES_NO", "", True),
        (20, "If yes, where did you work before?", "TEXT", "", False),
        (
            30,
            "How will you bring clients?",
            "SELECT",
            "Social Media\nWebsite\nNetwork\nOther",
            True,
        ),
        (40, "How many clients can you bring monthly?", "NUMBER", "", True),
        (50, "Which country or region will you target?", "TEXT", "", True),
        (60, "Additional notes", "TEXTAREA", "", False),
    ]
    for sort_order, label, input_type, choices, required in defaults:
        IBApplicationQuestion.objects.get_or_create(
            label=label,
            defaults={
                "sort_order": sort_order,
                "input_type": input_type,
                "choices": choices,
                "required": required,
                "is_active": True,
            },
        )


def noop_reverse(apps, schema_editor):
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("ib", "0003_ibcommissionsettings_ibgroupcommission_iblevel_and_more"),
    ]

    operations = [
        migrations.CreateModel(
            name="IBApplicationQuestion",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("sort_order", models.PositiveIntegerField(default=0)),
                ("label", models.CharField(max_length=300)),
                (
                    "input_type",
                    models.CharField(
                        choices=[
                            ("YES_NO", "Yes / No"),
                            ("TEXT", "Short text"),
                            ("TEXTAREA", "Long text"),
                            ("SELECT", "Single choice"),
                            ("MULTI", "Multiple choice"),
                            ("NUMBER", "Number"),
                        ],
                        default="TEXT",
                        max_length=20,
                    ),
                ),
                (
                    "choices",
                    models.TextField(
                        blank=True,
                        help_text="One option per line (for Single / Multiple choice).",
                    ),
                ),
                ("required", models.BooleanField(default=False)),
                ("is_active", models.BooleanField(default=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={
                "ordering": ["sort_order", "id"],
            },
        ),
        migrations.AddField(
            model_name="ibrequest",
            name="application_data",
            field=models.JSONField(blank=True, default=dict),
        ),
        migrations.RunPython(seed_default_ib_questions, noop_reverse),
    ]
