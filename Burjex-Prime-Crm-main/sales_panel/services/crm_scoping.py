"""Data scoping for sales managers (only their book)."""
from __future__ import annotations

from django.db.models import Q, QuerySet

from accounts.models import User
from marketing.models import Lead, SalesFunnelContactLog, SalesFunnelVisitor


def is_sales_scope(user: User) -> bool:
    return user.is_authenticated and user.role == User.Roles.SALES_MANAGER


def clients_qs_for_sales_user(user: User) -> QuerySet[User]:
    qs = User.objects.filter(role=User.Roles.CLIENT)
    if not is_sales_scope(user):
        return qs
    return qs.filter(
        Q(registered_via_sales_manager_id=user.pk)
        | Q(manager_client_assignments__manager_id=user.pk)
        | Q(sales_funnel_profile__assigned_manager_id=user.pk)
    ).distinct()


def leads_qs_for_sales_user(user: User) -> QuerySet[Lead]:
    qs = Lead.objects.all()
    if not is_sales_scope(user):
        return qs
    return qs.filter(assigned_to_id=user.pk)


def visitors_qs_for_sales_user(user: User) -> QuerySet[SalesFunnelVisitor]:
    qs = SalesFunnelVisitor.objects.all()
    if not is_sales_scope(user):
        return qs
    return qs.filter(assigned_manager_id=user.pk)


def contact_logs_qs_for_sales_user(user: User) -> QuerySet[SalesFunnelContactLog]:
    qs = SalesFunnelContactLog.objects.all()
    if not is_sales_scope(user):
        return qs
    client_ids = clients_qs_for_sales_user(user).values_list("id", flat=True)
    visitor_ids = visitors_qs_for_sales_user(user).values_list("id", flat=True)
    return qs.filter(Q(client_id__in=client_ids) | Q(visitor_id__in=visitor_ids))
