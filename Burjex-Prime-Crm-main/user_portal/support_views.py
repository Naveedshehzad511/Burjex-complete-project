from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.urls import reverse
from django.utils import timezone
from uuid import uuid4

from accounts.models import User
from accounts.permissions import role_required
from admin_panel.models import SupportIntegration, SupportSettings
from enterprise.staff_notify import broadcast_staff_notification
from live_chat.models import SupportTicket

PORTAL_ROLES = [User.Roles.CLIENT, User.Roles.TRADER, User.Roles.COPIER, User.Roles.IB]


@login_required
@role_required(PORTAL_ROLES)
def support_page(request):
    if request.method == "POST":
        subject = (request.POST.get("subject") or "").strip()
        description = (request.POST.get("description") or "").strip()
        category = (request.POST.get("category") or "").strip()
        priority = (request.POST.get("priority") or "").strip()

        valid_categories = {k for k, _ in SupportTicket.Category.choices}
        valid_priorities = {k for k, _ in SupportTicket.Priority.choices}

        if not subject or not description:
            messages.error(request, "Subject and description are required.")
            return redirect("user-support")
        if category not in valid_categories:
            messages.error(request, "Invalid category selected.")
            return redirect("user-support")
        if priority not in valid_priorities:
            messages.error(request, "Invalid priority selected.")
            return redirect("user-support")

        from datetime import timedelta
        
        recent = SupportTicket.objects.filter(
            user=request.user,
            subject=subject[:200],
            created_at__gte=timezone.now() - timedelta(minutes=2)
        ).first()
        
        if recent:
            messages.info(request, f"Ticket already created ({recent.ticket_number}).")
            return redirect("user-support")

        ticket = SupportTicket.objects.create(
            user=request.user,
            subject=subject[:200],
            description=description[:5000],
            category=category,
            priority=priority,
            status=SupportTicket.Status.PENDING,
            ticket_number=f"TKT-{timezone.now().strftime('%Y%m%d')}-{uuid4().hex[:8].upper()}",
            read_by_admin=False,
        )
        tok = f"[support_ticket:{ticket.id}]"
        broadcast_staff_notification(
            "New support ticket",
            f"{tok} {request.user.display_name()} created {ticket.ticket_number}: {ticket.subject}",
            action_url=f"{reverse('admin-tickets')}?tab={SupportTicket.Status.PENDING}&ticket_id={ticket.id}",
            dedupe_body_contains=tok,
        )
        messages.success(request, f"Ticket created successfully ({ticket.ticket_number}).")
        return redirect("user-support")

    rows = SupportIntegration.objects.filter(enabled=True, status="ACTIVE").order_by("integration_type")
    my_tickets = SupportTicket.objects.filter(user=request.user).order_by("-updated_at", "-id")[:25]
    return render(
        request,
        "user_portal/support.html",
        {
            "support_integrations": rows,
            "support_settings": SupportSettings.get_solo(),
            "my_tickets": my_tickets,
            "ticket_categories": SupportTicket.Category.choices,
            "ticket_priorities": SupportTicket.Priority.choices,
        },
    )

@login_required
@role_required(PORTAL_ROLES)
def ticket_detail(request, ticket_number):
    from django.shortcuts import get_object_or_404
    from live_chat.models import SupportTicketReply
    
    ticket = get_object_or_404(SupportTicket, ticket_number=ticket_number, user=request.user)
    
    # Mark as read by client if we want, currently there is unread_for_client on conversation but not on SupportTicket natively.
    # SupportTicket has read_by_admin.
    
    if request.method == "POST":
        message = (request.POST.get("message") or "").strip()
        attachment = request.FILES.get("attachment")
        
        if message or attachment:
            SupportTicketReply.objects.create(
                ticket=ticket,
                sender=request.user,
                is_admin=False,
                message=message[:5000],
                attachment=attachment
            )
            ticket.read_by_admin = False
            ticket.save(update_fields=["read_by_admin", "updated_at"])
            
            # Send notification to staff
            tok = f"[support_ticket:{ticket.id}]"
            broadcast_staff_notification(
                "New ticket reply",
                f"{tok} {request.user.display_name()} replied to {ticket.ticket_number}",
                action_url=f"{reverse('admin-tickets')}?tab={ticket.status}&ticket_id={ticket.id}",
                dedupe_body_contains=tok,
            )
            return redirect("user-ticket-detail", ticket_number=ticket.ticket_number)
            
    replies = ticket.replies.select_related("sender").order_by("created_at")
    return render(
        request,
        "user_portal/ticket_detail.html",
        {
            "ticket": ticket,
            "replies": replies,
        }
    )
