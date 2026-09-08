# Forex Broker CRM (Django)

This is a working Django project skeleton for a Forex broker CRM with:
- Admin Panel routes + dashboard metrics
- User Portal routes + trading account cards + wallet balance
- PostgreSQL-ready data models (with migrations generated)
- Payment gateways foundation for deposit/withdraw

## Prerequisites
1. Python 3.10+
2. PostgreSQL server

## Configure PostgreSQL (recommended via environment variables)
Set:
- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_HOST` (default: `localhost`)
- `POSTGRES_PORT` (default: `5432`)

## Install dependencies
```powershell
pip install -r requirements.txt
```

## Migrations
```powershell
python manage.py makemigrations
python manage.py migrate
```

## Seed payment gateways
```powershell
python manage.py seed_payment_gateways
```

## Seed MT5 groups / IB defaults (optional)
```powershell
python manage.py seed_mt5_groups
python manage.py seed_ib_defaults
```

## Create an admin user
```powershell
python manage.py createsuperuser
```

## Run locally
```powershell
python manage.py runserver
```

Routes:
- CRM Admin Panel: `/admin/dashboard/`
- User Portal: `/user/dashboard/`
- Login: `/accounts/login/`

