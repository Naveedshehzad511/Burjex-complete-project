from __future__ import annotations

from datetime import timedelta
from uuid import uuid4

from django.shortcuts import get_object_or_404
from django.urls import reverse
from django.utils import timezone
from rest_framework.parsers import FormParser, MultiPartParser
from rest_framework.views import APIView

from admin_panel.models import SupportIntegration
from api.permissions import IsAuthenticatedClient
from api.responses import error_response, not_found_response, success_response
from enterprise.staff_notify import broadcast_staff_notification
from live_chat.models import SupportTicket, SupportTicketReply


def _serialize_ticket(ticket: SupportTicket) -> dict:
    return {
        "id": ticket.id,
        "ticket_number": ticket.ticket_number,
        "subject": ticket.subject,
        "description": ticket.description,
        "category": ticket.category,
        "priority": ticket.priority,
        "status": ticket.status,
        "read_by_admin": ticket.read_by_admin,
        "created_at": ticket.created_at.isoformat() if ticket.created_at else None,
        "updated_at": ticket.updated_at.isoformat() if ticket.updated_at else None,
    }


def _serialize_reply(reply: SupportTicketReply) -> dict:
    return {
        "id": reply.id,
        "message": reply.message,
        "is_admin": reply.is_admin,
        "sender_id": reply.sender_id,
        "sender_name": reply.sender.display_name() if reply.sender else None,
        "attachment": reply.attachment.url if reply.attachment else None,
        "created_at": reply.created_at.isoformat() if reply.created_at else None,
    }


class SupportTicketsAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]
    parser_classes = [MultiPartParser, FormParser]

    def get(self, request):
        limit = min(int(request.query_params.get("limit") or 25), 100)
        rows = SupportIntegration.objects.filter(enabled=True, status="ACTIVE").order_by("integration_type")
        my_tickets = SupportTicket.objects.filter(user=request.user).order_by("-updated_at", "-id")[:limit]
        return success_response(
            {
                "integrations": [
                    {
                        "id": r.id,
                        "integration_type": r.integration_type,
                        "name": r.integration_name,
                        "status": r.status,
                    }
                    for r in rows
                ],
                "settings": {},
                "ticket_categories": [
                    {"value": k, "label": v} for k, v in SupportTicket.Category.choices
                ],
                "ticket_priorities": [
                    {"value": k, "label": v} for k, v in SupportTicket.Priority.choices
                ],
                "tickets": [_serialize_ticket(t) for t in my_tickets],
            },
            message="Support tickets retrieved successfully.",
        )

    def post(self, request):
        subject = (request.data.get("subject") or "").strip()
        description = (request.data.get("description") or "").strip()
        category = (request.data.get("category") or "").strip()
        priority = (request.data.get("priority") or "").strip()

        valid_categories = {k for k, _ in SupportTicket.Category.choices}
        valid_priorities = {k for k, _ in SupportTicket.Priority.choices}

        if not subject or not description:
            return error_response("Subject and description are required.")
        if category not in valid_categories:
            return error_response("Invalid category selected.")
        if priority not in valid_priorities:
            return error_response("Invalid priority selected.")

        recent = SupportTicket.objects.filter(
            user=request.user,
            subject=subject[:200],
            created_at__gte=timezone.now() - timedelta(minutes=2),
        ).first()
        if recent:
            return success_response(
                {"ticket": _serialize_ticket(recent), "duplicate": True},
                message=f"Ticket already created ({recent.ticket_number}).",
            )

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
        return success_response(
            {"ticket": _serialize_ticket(ticket)},
            message=f"Ticket created successfully ({ticket.ticket_number}).",
            status=201,
        )


class SupportTicketDetailAPIView(APIView):
    permission_classes = [IsAuthenticatedClient]
    parser_classes = [MultiPartParser, FormParser]

    def get(self, request, ticket_number: str):
        ticket = SupportTicket.objects.filter(ticket_number=ticket_number, user=request.user).first()
        if not ticket:
            return not_found_response("Support ticket not found.")
        replies = ticket.replies.select_related("sender").order_by("created_at")
        return success_response(
            {
                "ticket": _serialize_ticket(ticket),
                "replies": [_serialize_reply(r) for r in replies],
            },
            message="Support ticket retrieved successfully.",
        )

    def post(self, request, ticket_number: str):
        ticket = get_object_or_404(SupportTicket, ticket_number=ticket_number, user=request.user)
        message = (request.data.get("message") or "").strip()
        attachment = request.FILES.get("attachment")

        if not message and not attachment:
            return error_response("Message or attachment is required.")

        SupportTicketReply.objects.create(
            ticket=ticket,
            sender=request.user,
            is_admin=False,
            message=message[:5000],
            attachment=attachment,
        )
        ticket.read_by_admin = False
        ticket.save(update_fields=["read_by_admin", "updated_at"])

        tok = f"[support_ticket:{ticket.id}]"
        broadcast_staff_notification(
            "New ticket reply",
            f"{tok} {request.user.display_name()} replied to {ticket.ticket_number}",
            action_url=f"{reverse('admin-tickets')}?tab={ticket.status}&ticket_id={ticket.id}",
            dedupe_body_contains=tok,
        )
        replies = ticket.replies.select_related("sender").order_by("created_at")
        return success_response(
            {
                "ticket": _serialize_ticket(ticket),
                "replies": [_serialize_reply(r) for r in replies],
            },
            message="Reply submitted successfully.",
        )
