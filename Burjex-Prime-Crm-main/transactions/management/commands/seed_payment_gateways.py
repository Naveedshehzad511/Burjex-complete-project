from django.core.management.base import BaseCommand

from transactions.models import PaymentGateway


class Command(BaseCommand):
    help = "Seed default payment gateways for deposit/withdraw forms."

    def handle(self, *args, **options):
        gateways = [
            ("Bank Transfer", "BANK_TRANSFER"),
            ("Crypto", "CRYPTO"),
            ("USDT TRC20", "USDT_TRC20"),
            ("USDT ERC20", "USDT_ERC20"),
            ("Match2Pay", "MATCH2PAY"),
            ("HaveDotPay", "HAVEDOTPAY"),
            ("AppDotPay", "APPDOTPAY"),
        ]

        created = 0
        for name, code in gateways:
            obj, was_created = PaymentGateway.objects.update_or_create(code=code, defaults={"name": name, "is_active": True})
            if was_created:
                created += 1

        self.stdout.write(self.style.SUCCESS(f"Payment gateways seeded. New: {created}"))

