"""Management command to seed default NotificationTemplate rows.

Usage:
    python manage.py seed_notification_templates

Idempotent: skips templates whose event_key already exists.
"""

from django.core.management.base import BaseCommand

from email_notifications.models import NotificationTemplate


# (event_key, name, category, subject, html_content)
DEFAULT_TEMPLATES = [
    (
        "welcome_email",
        "Welcome Email",
        NotificationTemplate.Category.AUTH,
        "Welcome to {{company_name}}",
        "<h2>Welcome, {{user_name}}!</h2>"
        "<p>Thank you for registering with <strong>{{company_name}}</strong>.</p>"
        "<p>Your account has been created successfully.</p>"
        "<p>Best regards,<br/>{{company_name}} Team</p>",
    ),
    (
        "email_verification",
        "Email Verification",
        NotificationTemplate.Category.AUTH,
        "Verify your email - {{company_name}}",
        "<h2>Verify Your Email</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Please verify your email address using the button below.</p>"
        '<p><a href="{{verification_link}}" class="email-btn" data-email-btn="primary">Verify Email</a></p>'
        "<p>If the button does not work, open this link: {{verification_link}}</p>",
    ),
    (
        "otp_verification",
        "OTP Verification",
        NotificationTemplate.Category.AUTH,
        "Your verification code - {{company_name}}",
        "<h2>Verification Code</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your one-time verification code is:</p>"
        "<p style='font-size:28px;font-weight:bold;letter-spacing:6px;"
        "background:#f1f5f9;padding:16px 24px;display:inline-block;"
        "border-radius:8px;color:#0f172a;'>{{otp}}</p>"
        "<p>This code expires soon. Do not share it with anyone.</p>",
    ),
    (
        "forgot_password",
        "Forgot Password",
        NotificationTemplate.Category.AUTH,
        "Password reset request - {{company_name}}",
        "<h2>Password Reset Request</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>We received a request to reset your password.</p>"
        '<p><a href="{{reset_link}}" class="email-btn" data-email-btn="primary">Reset Password</a></p>'
        "<p>If you did not request this, you can safely ignore this email.</p>",
    ),
    (
        "password_reset",
        "Password Reset",
        NotificationTemplate.Category.AUTH,
        "Password Reset - {{company_name}}",
        "<h2>Password Reset</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your password reset request is ready.</p>"
        '<p><a href="{{reset_link}}" class="email-btn" data-email-btn="primary">Reset Password</a></p>',
    ),
    (
        "login_alert",
        "Login Alert",
        NotificationTemplate.Category.AUTH,
        "New login alert - {{company_name}}",
        "<h2>New Login Detected</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>A login was detected on your account.</p>"
        "<p><strong>Time:</strong> {{login_time}}</p>"
        "<p><strong>IP Address:</strong> {{ip_address}}</p>"
        "<p>If this was not you, please change your password immediately.</p>",
    ),
    (
        "deposit_confirmation",
        "Deposit Confirmation",
        NotificationTemplate.Category.TRADING,
        "Deposit Confirmed - {{amount}}",
        "<h2>Deposit Confirmed</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your deposit of <strong>{{amount}}</strong> has been approved.</p>"
        "<p><strong>Date:</strong> {{date}}</p>",
    ),
    (
        "withdrawal_confirmation",
        "Withdrawal Confirmation",
        NotificationTemplate.Category.TRADING,
        "Withdrawal Processed - {{amount}}",
        "<h2>Withdrawal Processed</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your withdrawal request of <strong>{{amount}}</strong> has been approved.</p>"
        "<p><strong>Date:</strong> {{date}}</p>",
    ),
    (
        "internal_transfer_confirmation",
        "Internal Transfer Confirmation",
        NotificationTemplate.Category.TRADING,
        "Internal transfer confirmed - {{amount}}",
        "<h2>Internal Transfer Confirmed</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your internal transfer of <strong>{{amount}}</strong> was completed.</p>"
        "<p><strong>From:</strong> {{from_account}}</p>"
        "<p><strong>To:</strong> {{to_account}}</p>"
        "<p><strong>Date:</strong> {{date}}</p>",
    ),
    (
        "trading_notifications",
        "Trading Notification",
        NotificationTemplate.Category.TRADING,
        "Trading notification - {{company_name}}",
        "<h2>Trading Notification</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>{{trading_message}}</p>"
        "<p><strong>Account:</strong> {{account_number}}</p>",
    ),
    (
        "kyc_approved",
        "KYC Approved",
        NotificationTemplate.Category.SUPPORT,
        "KYC Verification Approved - {{company_name}}",
        "<h2>KYC Approved</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your identity verification has been <strong>approved</strong>.</p>",
    ),
    (
        "kyc_rejected",
        "KYC Rejected",
        NotificationTemplate.Category.SUPPORT,
        "KYC Verification Update - {{company_name}}",
        "<h2>KYC Verification Update</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your identity verification could not be approved.</p>"
        "<p><strong>Reason:</strong> {{reason}}</p>",
    ),
    (
        "ticket_created",
        "Ticket Created",
        NotificationTemplate.Category.SUPPORT,
        "Support ticket created - {{ticket_number}}",
        "<h2>Support Ticket Created</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your support ticket <strong>{{ticket_number}}</strong> has been created.</p>"
        "<p><strong>Subject:</strong> {{ticket_subject}}</p>",
    ),
    (
        "ticket_reply",
        "Ticket Reply",
        NotificationTemplate.Category.SUPPORT,
        "New reply on ticket {{ticket_number}}",
        "<h2>Support Reply</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>There is a new reply on ticket <strong>{{ticket_number}}</strong>.</p>"
        "<p>{{reply_message}}</p>",
    ),
    (
        "ticket_closed",
        "Ticket Closed",
        NotificationTemplate.Category.SUPPORT,
        "Support ticket closed - {{ticket_number}}",
        "<h2>Ticket Closed</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your support ticket <strong>{{ticket_number}}</strong> has been closed.</p>",
    ),
    (
        "ticket_status_updated",
        "Ticket Status Updated",
        NotificationTemplate.Category.SUPPORT,
        "Support ticket updated - {{ticket_number}}",
        "<h2>Ticket Status Updated</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your ticket <strong>{{ticket_number}}</strong> status is now <strong>{{ticket_status}}</strong>.</p>",
    ),
    (
        "ib_registration",
        "IB Registration",
        NotificationTemplate.Category.IB,
        "IB registration received - {{company_name}}",
        "<h2>IB Registration Received</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your IB registration/application has been received.</p>"
        "<p><strong>Status:</strong> {{ib_status}}</p>",
    ),
    (
        "ib_request_approved",
        "Partner Approval",
        NotificationTemplate.Category.IB,
        "Partner application approved - {{company_name}}",
        "<h2>Partner Application Approved</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your IB/partner request has been approved.</p>"
        "<p>{{ib_reason}}</p>",
    ),
    (
        "ib_request_rejected",
        "Partner Rejection",
        NotificationTemplate.Category.IB,
        "Partner application update - {{company_name}}",
        "<h2>Partner Application Update</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>Your IB/partner request was rejected.</p>"
        "<p><strong>Reason:</strong> {{ib_reason}}</p>",
    ),
    (
        "promotion_email",
        "Promotion Email",
        NotificationTemplate.Category.MARKETING,
        "Promotion - {{promotion_title}}",
        "<h2>{{promotion_title}}</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>{{promotion_message}}</p>"
        '<p><a href="{{promotion_link}}" class="email-btn" data-email-btn="primary">View Promotion</a></p>',
    ),
    (
        "campaign_email",
        "Campaign Email",
        NotificationTemplate.Category.MARKETING,
        "{{campaign_name}} - {{company_name}}",
        "<h2>{{campaign_name}}</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>{{campaign_message}}</p>"
        '<p><a href="{{campaign_link}}" class="email-btn" data-email-btn="primary">Learn More</a></p>',
    ),
    (
        "market_update",
        "Market Update",
        NotificationTemplate.Category.MARKETING,
        "Market update - {{market_title}}",
        "<h2>{{market_title}}</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>{{market_summary}}</p>",
    ),
    (
        "webinar_invitation",
        "Webinar Invitation",
        NotificationTemplate.Category.MARKETING,
        "Webinar invitation - {{webinar_title}}",
        "<h2>{{webinar_title}}</h2>"
        "<p>Dear {{user_name}},</p>"
        "<p>You are invited to our webinar.</p>"
        "<p><strong>Date:</strong> {{webinar_date}}</p>"
        '<p><a href="{{webinar_link}}" class="email-btn" data-email-btn="primary">Join Webinar</a></p>',
    ),
]


class Command(BaseCommand):
    help = "Create default NotificationTemplate rows for critical email workflows."

    def handle(self, *args, **options):
        created_count = 0
        skipped_count = 0

        for event_key, name, category, subject, html_content in DEFAULT_TEMPLATES:
            _, was_created = NotificationTemplate.objects.get_or_create(
                event_key=event_key,
                defaults={
                    "name": name,
                    "category": category,
                    "subject": subject,
                    "html_content": html_content,
                    "is_active": True,
                },
            )
            if was_created:
                created_count += 1
                self.stdout.write(self.style.SUCCESS(f"  [+] Created: {name} [{event_key}]"))
            else:
                skipped_count += 1
                self.stdout.write(f"  [-] Skipped (exists): {name} [{event_key}]")

        self.stdout.write("")
        self.stdout.write(
            self.style.SUCCESS(
                f"Done. Created {created_count}, skipped {skipped_count} "
                f"(total templates: {NotificationTemplate.objects.count()})."
            )
        )
