from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


def seed_tag_categories(apps, schema_editor):
    TagCategory = apps.get_model("admin_panel", "TagCategory")
    defaults = [
        ("risk", "Risk Tags"),
        ("account_type", "Account Type Tags"),
        ("ib_level", "IB Level Tags"),
        ("lead_handling", "Lead Handling Tags"),
        ("feature", "Feature Tags"),
        ("client", "Client Tags"),
    ]
    for type_key, name in defaults:
        TagCategory.objects.get_or_create(type=type_key, defaults={"name": name})


class Migration(migrations.Migration):
    dependencies = [
        ("admin_panel", "0035_advanced_email_template_system"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="TagCategory",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=120)),
                (
                    "type",
                    models.CharField(
                        choices=[
                            ("risk", "Risk Tags"),
                            ("account_type", "Account Type Tags"),
                            ("ib_level", "IB Level Tags"),
                            ("lead_handling", "Lead Handling Tags"),
                            ("feature", "Feature Tags"),
                            ("client", "Client Tags"),
                        ],
                        db_index=True,
                        max_length=40,
                        unique=True,
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={"ordering": ["name"]},
        ),
        migrations.CreateModel(
            name="Tag",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=120)),
                ("description", models.TextField(blank=True, default="")),
                ("color", models.CharField(default="#64748b", max_length=20)),
                ("is_active", models.BooleanField(db_index=True, default=True)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                (
                    "category",
                    models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="tags", to="admin_panel.tagcategory"),
                ),
            ],
            options={"ordering": ["category__name", "name"]},
        ),
        migrations.CreateModel(
            name="UserTag",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("notes", models.CharField(blank=True, default="", max_length=255)),
                ("assigned_at", models.DateTimeField(auto_now_add=True)),
                (
                    "assigned_by",
                    models.ForeignKey(
                        blank=True,
                        null=True,
                        on_delete=django.db.models.deletion.SET_NULL,
                        related_name="assigned_user_tags",
                        to=settings.AUTH_USER_MODEL,
                    ),
                ),
                ("tag", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="user_tags", to="admin_panel.tag")),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="user_tags", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ["-assigned_at"]},
        ),
        migrations.AddConstraint(
            model_name="tag",
            constraint=models.UniqueConstraint(fields=("category", "name"), name="uniq_tag_category_name"),
        ),
        migrations.AddConstraint(
            model_name="usertag",
            constraint=models.UniqueConstraint(fields=("user", "tag"), name="uniq_user_tag"),
        ),
        migrations.RunPython(seed_tag_categories, migrations.RunPython.noop),
    ]
