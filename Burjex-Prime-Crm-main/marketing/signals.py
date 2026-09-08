from django.conf import settings
from django.db.models.signals import post_save
from django.dispatch import receiver

from accounts.models import User

from .models import SalesFunnelProfile, SalesFunnelVisitor


@receiver(post_save, sender=User)
def link_funnel_visitor_on_client_save(sender, instance: User, created: bool, **kwargs) -> None:
    if instance.role != User.Roles.CLIENT or not instance.email:
        return
    SalesFunnelVisitor.objects.filter(
        email__iexact=instance.email.strip(),
        converted_user__isnull=True,
    ).update(converted_user=instance)


@receiver(post_save, sender=User)
def ensure_sales_funnel_profile(sender, instance: User, created: bool, **kwargs) -> None:
    if instance.role != User.Roles.CLIENT:
        return
    SalesFunnelProfile.objects.get_or_create(user=instance)
