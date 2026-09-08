from django.db import models
from django.conf import settings

class MT5Deal(models.Model):
    """
    Stores MT5 deals synchronized from the broker to support Risk Monitor 
    and other modules without affecting the IB simulation logic.
    """
    deal_ticket = models.CharField(max_length=64, unique=True, db_index=True)
    order_ticket = models.CharField(max_length=64, blank=True, default="", db_index=True)
    position_ticket = models.CharField(max_length=64, blank=True, default="", db_index=True)
    
    login = models.CharField(max_length=64, db_index=True)
    client = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="mt5_deals",
    )
    
    symbol = models.CharField(max_length=64, blank=True, default="", db_index=True)
    action = models.IntegerField(help_text="MT5 Deal Action (0=Buy, 1=Sell, etc.)")
    entry_type = models.IntegerField(help_text="MT5 Deal Entry (0=In, 1=Out, etc.)")
    
    volume = models.DecimalField(max_digits=20, decimal_places=4, default=0)
    price = models.DecimalField(max_digits=20, decimal_places=6, default=0)
    profit = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    commission = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    swap = models.DecimalField(max_digits=20, decimal_places=2, default=0)
    
    time = models.DateTimeField(db_index=True)
    time_msc = models.BigIntegerField(default=0)
    
    created_at = models.DateTimeField(auto_now_add=True)
    
    class Meta:
        ordering = ["-time"]
        verbose_name = "MT5 Deal"
        verbose_name_plural = "MT5 Deals"
        indexes = [
            models.Index(fields=["login", "time"]),
            models.Index(fields=["symbol", "time"]),
        ]

    def __str__(self):
        return f"Deal {self.deal_ticket} - {self.login}"

    @property
    def lots(self):
        return float(self.volume) / 10000.0 if self.volume else 0.0
