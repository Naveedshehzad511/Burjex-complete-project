from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0079_userportalthemesettings"),
    ]

    operations = [
        migrations.AddField(model_name="userportalthemesettings", name="sidebar_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="sidebar_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="sidebar_hover_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="sidebar_active_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="topbar_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="topbar_border_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="topbar_title_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="button_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="button_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="button_hover_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="card_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="card_border_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="card_shadow", field=models.CharField(blank=True, default="", max_length=160)),
        migrations.AddField(model_name="userportalthemesettings", name="page_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="muted_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="mobile_button_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="mobile_button_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="table_header_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="table_row_hover_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="font_family", field=models.CharField(blank=True, default="", max_length=160)),
        migrations.AddField(model_name="userportalthemesettings", name="sidebar_width_px", field=models.PositiveIntegerField(blank=True, null=True)),
        migrations.AddField(model_name="userportalthemesettings", name="logo_size_px", field=models.PositiveIntegerField(blank=True, null=True)),
        migrations.AddField(model_name="userportalthemesettings", name="border_radius_px", field=models.PositiveIntegerField(blank=True, null=True)),
        migrations.AddField(model_name="userportalthemesettings", name="body_font_size_px", field=models.PositiveIntegerField(blank=True, null=True)),
        migrations.AddField(model_name="userportalthemesettings", name="h1_font_size_px", field=models.PositiveIntegerField(blank=True, null=True)),
        migrations.AddField(model_name="userportalthemesettings", name="h2_font_size_px", field=models.PositiveIntegerField(blank=True, null=True)),
    ]
