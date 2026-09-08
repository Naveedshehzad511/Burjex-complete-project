from django.utils import timezone
from datetime import timedelta
from accounts.models import User
from accounts.views import _send_verification_email
from django.test import RequestFactory
import uuid
since = timezone.now() - timedelta(hours=96)
qs = list(User.objects.filter(role=User.Roles.CLIENT, date_joined__gte=since, email_verified=False).order_by('-date_joined')[:10])
print('UNVERIFIED_COUNT', len(qs))
rf = RequestFactory()
req = rf.get('/')
req.META['HTTP_HOST'] = '5.226.139.8'
req.META['SERVER_NAME'] = '5.226.139.8'
req.META['wsgi.url_scheme'] = 'http'
for u in qs:
    if not (u.email_token or '').strip():
        u.email_token = uuid.uuid4().hex
        u.email_token_created_at = timezone.now()
        u.save(update_fields=['email_token', 'email_token_created_at'])
        print('TOKEN_ISSUED', u.pk, u.email)
    try:
        _send_verification_email(u, req)
        print('RESEND_OK', u.pk, u.email)
    except Exception as ex:
        print('RESEND_FAIL', u.pk, u.email, type(ex).__name__, ex)
