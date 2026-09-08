from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("admin_panel", "0080_userportalthemesettings_design_fields"),
    ]

    operations = [
        migrations.AddField(model_name="userportalthemesettings", name="dark_page_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_muted_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_sidebar_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_sidebar_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_sidebar_hover_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_sidebar_active_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_topbar_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_topbar_border_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_topbar_title_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_button_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_button_text_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_button_hover_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_card_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_card_border_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_table_header_bg_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_table_row_hover_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_mobile_button_color", field=models.CharField(blank=True, default="", max_length=32)),
        migrations.AddField(model_name="userportalthemesettings", name="dark_mobile_button_text_color", field=models.CharField(blank=True, default="", max_length=32)),
    ]
