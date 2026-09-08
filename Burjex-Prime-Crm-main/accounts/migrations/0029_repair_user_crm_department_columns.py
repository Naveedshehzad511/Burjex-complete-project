# Repairs DBs where code expects crm_department_id / registered_via_sales_manager_id
# but the column is missing (e.g. old sqlite file, interrupted migrate).

from django.db import migrations


def _sqlite_columns(cursor, table: str) -> set[str]:
    cursor.execute(f'PRAGMA table_info("{table}")')
    return {row[1] for row in cursor.fetchall()}


def repair_sqlite_user_columns(apps, schema_editor) -> None:
    connection = schema_editor.connection
    if connection.vendor != "sqlite":
        return
    with connection.cursor() as cursor:
        cols = _sqlite_columns(cursor, "accounts_user")
        if "crm_department_id" not in cols:
            cursor.execute(
                'ALTER TABLE accounts_user ADD COLUMN crm_department_id bigint NULL '
                'REFERENCES admin_panel_crmdepartment(id) DEFERRABLE INITIALLY DEFERRED'
            )
        if "registered_via_sales_manager_id" not in cols:
            cursor.execute(
                'ALTER TABLE accounts_user ADD COLUMN registered_via_sales_manager_id bigint NULL '
                'REFERENCES accounts_user(id) DEFERRABLE INITIALLY DEFERRED'
            )


def repair_postgres_user_columns(apps, schema_editor) -> None:
    connection = schema_editor.connection
    if connection.vendor != "postgresql":
        return
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = 'accounts_user'
            """
        )
        cols = {row[0] for row in cursor.fetchall()}
        if "crm_department_id" not in cols:
            cursor.execute(
                'ALTER TABLE accounts_user ADD COLUMN crm_department_id bigint NULL '
                'REFERENCES admin_panel_crmdepartment(id) DEFERRABLE INITIALLY DEFERRED'
            )
        if "registered_via_sales_manager_id" not in cols:
            cursor.execute(
                'ALTER TABLE accounts_user ADD COLUMN registered_via_sales_manager_id bigint NULL '
                'REFERENCES accounts_user(id) DEFERRABLE INITIALLY DEFERRED'
            )


def forwards(apps, schema_editor):
    repair_sqlite_user_columns(apps, schema_editor)
    repair_postgres_user_columns(apps, schema_editor)


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0028_crm_sales_rbac"),
    ]

    operations = [
        migrations.RunPython(forwards, migrations.RunPython.noop),
    ]
