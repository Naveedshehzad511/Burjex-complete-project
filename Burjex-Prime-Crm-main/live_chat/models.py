from __future__ import annotations

from django.conf import settings
from django.db import models


def chat_attachment_path(instance: "ChatMessage", filename: str) -> str:
    return f"chat_attachments/{instance.conversation_id}/{filename}"


class ChatSettings(models.Model):
    class WidgetPosition(models.TextChoices):
        BOTTOM_RIGHT = "BOTTOM_RIGHT", "Bottom Right"
        BOTTOM_LEFT = "BOTTOM_LEFT", "Bottom Left"
        CUSTOM = "CUSTOM", "Custom Position"

    enable_live_chat = models.BooleanField(default=True)
    show_on_public_pages = models.BooleanField(default=True)
    auto_assign_conversations = models.BooleanField(default=True)
    enable_attachments = models.BooleanField(default=True)
    show_typing_indicator = models.BooleanField(default=True)
    missed_chat_timeout_seconds = models.PositiveIntegerField(default=120)
    idle_timeout_seconds = models.PositiveIntegerField(default=300)
    max_concurrent_chats = models.PositiveIntegerField(default=10)
    enable_welcome_message = models.BooleanField(default=True)
    welcome_message_text = models.TextField(blank=True, default="Hi! Welcome. How can we help you today?")
    welcome_delay_seconds = models.PositiveIntegerField(default=2)
    enable_offline_message = models.BooleanField(default=True)
    offline_message_text = models.TextField(blank=True, default="We are offline right now. Please leave a message.")
    offline_delay_seconds = models.PositiveIntegerField(default=2)
    collect_email_when_offline = models.BooleanField(default=True)
    enable_away_message = models.BooleanField(default=True)
    away_message_text = models.TextField(blank=True, default="Our agents are away. We will reply shortly.")
    away_delay_seconds = models.PositiveIntegerField(default=2)
    enable_end_message = models.BooleanField(default=True)
    end_message_text = models.TextField(blank=True, default="Thanks for chatting with us.")
    end_delay_seconds = models.PositiveIntegerField(default=1)
    widget_color = models.CharField(max_length=20, default="#0B3C5D")
    text_color = models.CharField(max_length=20, default="#FFFFFF")
    background_color = models.CharField(max_length=20, default="#FFFFFF")
    widget_position = models.CharField(max_length=20, choices=WidgetPosition.choices, default=WidgetPosition.BOTTOM_RIGHT)
    custom_position_css = models.CharField(max_length=255, blank=True, default="")
    button_size_px = models.PositiveIntegerField(default=56)
    offset_x_px = models.PositiveIntegerField(default=24)
    offset_y_px = models.PositiveIntegerField(default=24)
    widget_title = models.CharField(max_length=120, default="Live Chat")
    widget_subtitle = models.CharField(max_length=255, default="Chat with our support team")
    show_agent_photo = models.BooleanField(default=True)
    auto_open = models.BooleanField(default=False)
    show_on_mobile = models.BooleanField(default=True)
    sound_notifications = models.BooleanField(default=True)
    guest_info_collection = models.BooleanField(default=True)
    conversation_persistence = models.BooleanField(default=True)
    source_tracking = models.BooleanField(default=True)
    embed_widget_enabled = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "chat_settings"

    @classmethod
    def singleton(cls) -> "ChatSettings":
        return cls.objects.first() or cls.objects.create()


class QuickReply(models.Model):
    class Categories(models.TextChoices):
        GREETINGS = "GREETINGS", "Greetings"
        QUESTIONS = "QUESTIONS", "Questions"
        RESPONSES = "RESPONSES", "Responses"
        CLOSING = "CLOSING", "Closing"

    title = models.CharField(max_length=120)
    slash_command = models.CharField(max_length=60, unique=True)
    message = models.TextField()
    category = models.CharField(max_length=20, choices=Categories.choices, default=Categories.RESPONSES)
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "quick_replies"
        ordering = ["category", "title"]


class ChatAISettings(models.Model):
    response_tone = models.CharField(max_length=40, default="warm")
    max_response_length = models.PositiveIntegerField(default=400)
    creativity_temperature = models.DecimalField(max_digits=3, decimal_places=2, default=0.3)
    include_user_info = models.BooleanField(default=True)
    include_page_url = models.BooleanField(default=True)
    recent_messages_count = models.PositiveIntegerField(default=10)
    system_role = models.CharField(max_length=120, default="Support assistant")
    ai_instructions = models.TextField(
        default="Friendly responses. Concise replies. Warm tone. Helpful responses. Ask questions when needed."
    )
    auto_suggest_replies = models.BooleanField(default=True)
    knowledge_base = models.TextField(blank=True, default="")
    enabled = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "chat_ai_settings"

    @classmethod
    def singleton(cls) -> "ChatAISettings":
        return cls.objects.first() or cls.objects.create()


class ChatBusinessHours(models.Model):
    timezone = models.CharField(max_length=64, default="UTC")
    mon_enabled = models.BooleanField(default=True)
    tue_enabled = models.BooleanField(default=True)
    wed_enabled = models.BooleanField(default=True)
    thu_enabled = models.BooleanField(default=True)
    fri_enabled = models.BooleanField(default=True)
    sat_enabled = models.BooleanField(default=False)
    sun_enabled = models.BooleanField(default=False)
    start_time = models.TimeField(default="09:00")
    end_time = models.TimeField(default="18:00")
    mon_start_time = models.TimeField(default="09:00")
    mon_end_time = models.TimeField(default="18:00")
    tue_start_time = models.TimeField(default="09:00")
    tue_end_time = models.TimeField(default="18:00")
    wed_start_time = models.TimeField(default="09:00")
    wed_end_time = models.TimeField(default="18:00")
    thu_start_time = models.TimeField(default="09:00")
    thu_end_time = models.TimeField(default="18:00")
    fri_start_time = models.TimeField(default="09:00")
    fri_end_time = models.TimeField(default="18:00")
    sat_start_time = models.TimeField(default="09:00")
    sat_end_time = models.TimeField(default="18:00")
    sun_start_time = models.TimeField(default="09:00")
    sun_end_time = models.TimeField(default="18:00")
    offline_detection = models.BooleanField(default=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "chat_business_hours"

    @classmethod
    def singleton(cls) -> "ChatBusinessHours":
        return cls.objects.first() or cls.objects.create()


class ChatNotificationSettings(models.Model):
    new_chat_sound = models.BooleanField(default=True)
    new_message_sound = models.BooleanField(default=True)
    volume_percent = models.PositiveIntegerField(default=80)
    enable_browser_notifications = models.BooleanField(default=True)
    agent_online_alert = models.BooleanField(default=True)
    agent_offline_alert = models.BooleanField(default=True)
    queue_threshold_alert = models.BooleanField(default=True)
    queue_threshold_number = models.PositiveIntegerField(default=5)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "chat_notifications"

    @classmethod
    def singleton(cls) -> "ChatNotificationSettings":
        return cls.objects.first() or cls.objects.create()


class ChatAgent(models.Model):
    user = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="chat_agent_profile")
    is_online = models.BooleanField(default=False)
    max_concurrent_chats = models.PositiveIntegerField(default=5)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        db_table = "chat_agents"


class ChatConversation(models.Model):
    class Status(models.TextChoices):
        QUEUED = "QUEUED", "Queued"
        ACTIVE = "ACTIVE", "Active"
        MISSED = "MISSED", "Missed"
        CLOSED = "CLOSED", "Closed"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="chat_conversations",
    )
    assigned_agent = models.ForeignKey(
        ChatAgent, null=True, blank=True, on_delete=models.SET_NULL, related_name="conversations"
    )
    session_key = models.CharField(max_length=64, blank=True, default="", db_index=True)
    guest_name = models.CharField(max_length=120, blank=True, default="")
    guest_email = models.CharField(max_length=255, blank=True, default="")
    page_url = models.CharField(max_length=500, blank=True, default="")
    source = models.CharField(max_length=80, blank=True, default="website")
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.QUEUED, db_index=True)
    is_ticket = models.BooleanField(default=False)
    ticket_number = models.CharField(max_length=40, blank=True, default="", db_index=True)
    unread_for_admin = models.BooleanField(default=True)
    unread_for_client = models.BooleanField(default=False)
    started_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    ended_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        db_table = "chat_conversations"
        ordering = ["-updated_at"]


class ChatMessage(models.Model):
    class SenderType(models.TextChoices):
        GUEST = "GUEST", "Guest"
        CLIENT = "CLIENT", "Client"
        AGENT = "AGENT", "Agent"
        AI = "AI", "AI"
        SYSTEM = "SYSTEM", "System"

    conversation = models.ForeignKey(ChatConversation, on_delete=models.CASCADE, related_name="messages")
    sender_user = models.ForeignKey(
        settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name="chat_messages"
    )
    sender_type = models.CharField(max_length=20, choices=SenderType.choices, default=SenderType.GUEST)
    text = models.TextField(blank=True, default="")
    attachment = models.FileField(upload_to=chat_attachment_path, blank=True, null=True)
    is_typing = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = "chat_messages"
        ordering = ["id"]


class SupportTicket(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        OPEN = "OPEN", "Open"
        IN_PROGRESS = "IN_PROGRESS", "In Progress"
        RESOLVED = "RESOLVED", "Resolved"
        CLOSED = "CLOSED", "Closed"

    class Category(models.TextChoices):
        ACCOUNT_RELATED = "ACCOUNT_RELATED", "Account Related"
        BILLING_RELATED = "BILLING_RELATED", "Billing Related"
        GENERAL_INQUIRY = "GENERAL_INQUIRY", "General Inquiry"
        PAYMENT_RELATED = "PAYMENT_RELATED", "Payment Related"
        TECHNICAL_SUPPORT = "TECHNICAL_SUPPORT", "Technical Support"

    class Priority(models.TextChoices):
        LOW = "LOW", "Low"
        MEDIUM = "MEDIUM", "Medium"
        HIGH = "HIGH", "High"
        URGENT = "URGENT", "Urgent"

    user = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="support_tickets")
    subject = models.CharField(max_length=200)
    description = models.TextField()
    category = models.CharField(max_length=30, choices=Category.choices, default=Category.GENERAL_INQUIRY)
    priority = models.CharField(max_length=10, choices=Priority.choices, default=Priority.MEDIUM)
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.PENDING, db_index=True)
    ticket_number = models.CharField(max_length=40, unique=True, db_index=True)
    read_by_admin = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    resolved_at = models.DateTimeField(null=True, blank=True)
    closed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-updated_at", "-id"]


class SupportTicketReply(models.Model):
    ticket = models.ForeignKey(SupportTicket, on_delete=models.CASCADE, related_name="replies")
    sender = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL)
    is_admin = models.BooleanField(default=False)
    message = models.TextField()
    attachment = models.FileField(upload_to="ticket_attachments/", blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["id"]

