# Generated manually for KYC component lifecycle + ID document sides.

from django.db import migrations, models


def forwards_migrate_kyc_status_values(apps, schema_editor):
    User = apps.get_model("accounts", "User")
    KYCIdentity = apps.get_model("accounts", "KYCIdentity")
    KYCAddress = apps.get_model("accounts", "KYCAddress")

    User.objects.filter(kyc_identity_front_status="approved").update(kyc_identity_front_status="verified")
    User.objects.filter(kyc_identity_back_status="approved").update(kyc_identity_back_status="verified")
    User.objects.filter(kyc_address_status="approved").update(kyc_address_status="verified")
    User.objects.filter(kyc_final_status="approved").update(kyc_final_status="verified")

    for u in User.objects.all().iterator(chunk_size=200):
        id_row = KYCIdentity.objects.filter(user_id=u.id).order_by("-created_at").first()
        addr_row = KYCAddress.objects.filter(user_id=u.id).order_by("-created_at").first()
        front = bool(id_row and id_row.front_file)
        back = bool(id_row and id_row.back_file)
        addr_file = bool(addr_row and addr_row.document_file)

        fs = u.kyc_identity_front_status
        if fs == "pending" and not front:
            fs = "incomplete"
        bs = u.kyc_identity_back_status
        if bs == "pending" and not back:
            bs = "incomplete"
        ads = u.kyc_address_status
        if ads == "pending" and not addr_file:
            ads = "incomplete"

        if "rejected" in (fs, bs, ads):
            nf = "rejected"
        elif fs == "verified" and bs == "verified" and ads == "verified":
            nf = "verified"
        elif fs == "incomplete" and bs == "incomplete" and ads == "incomplete":
            nf = "incomplete"
        else:
            nf = "pending"

        fields = []
        if u.kyc_identity_front_status != fs:
            u.kyc_identity_front_status = fs
            fields.append("kyc_identity_front_status")
        if u.kyc_identity_back_status != bs:
            u.kyc_identity_back_status = bs
            fields.append("kyc_identity_back_status")
        if u.kyc_address_status != ads:
            u.kyc_address_status = ads
            fields.append("kyc_address_status")
        if u.kyc_final_status != nf:
            u.kyc_final_status = nf
            fields.append("kyc_final_status")

        if fields:
            u.save(update_fields=fields)


def noop_reverse(apps, schema_editor):
    pass


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0017_user_kyc_component_statuses"),
    ]

    operations = [
        migrations.AlterField(
            model_name="document",
            name="doc_type",
            field=models.CharField(
                choices=[
                    ("PASSPORT", "Passport"),
                    ("NATIONAL_ID", "National ID"),
                    ("ID_DOCUMENT_FRONT", "ID Document (front)"),
                    ("ID_DOCUMENT_BACK", "ID Document (back)"),
                    ("UTILITY_BILL", "Utility Bill"),
                    ("PROOF_OF_ADDRESS", "Proof of Address"),
                    ("SELFIE", "Selfie / Liveness"),
                    ("OTHER", "Other"),
                ],
                default="OTHER",
                max_length=40,
            ),
        ),
        migrations.AlterField(
            model_name="user",
            name="kyc_identity_front_status",
            field=models.CharField(
                choices=[
                    ("incomplete", "Incomplete"),
                    ("pending", "Pending"),
                    ("verified", "Verified"),
                    ("rejected", "Rejected"),
                ],
                default="incomplete",
                max_length=16,
            ),
        ),
        migrations.AlterField(
            model_name="user",
            name="kyc_identity_back_status",
            field=models.CharField(
                choices=[
                    ("incomplete", "Incomplete"),
                    ("pending", "Pending"),
                    ("verified", "Verified"),
                    ("rejected", "Rejected"),
                ],
                default="incomplete",
                max_length=16,
            ),
        ),
        migrations.AlterField(
            model_name="user",
            name="kyc_address_status",
            field=models.CharField(
                choices=[
                    ("incomplete", "Incomplete"),
                    ("pending", "Pending"),
                    ("verified", "Verified"),
                    ("rejected", "Rejected"),
                ],
                default="incomplete",
                max_length=16,
            ),
        ),
        migrations.AlterField(
            model_name="user",
            name="kyc_final_status",
            field=models.CharField(
                choices=[
                    ("incomplete", "Incomplete"),
                    ("pending", "Pending"),
                    ("verified", "Verified"),
                    ("rejected", "Rejected"),
                ],
                default="incomplete",
                max_length=16,
            ),
        ),
        migrations.RunPython(forwards_migrate_kyc_status_values, noop_reverse),
    ]
