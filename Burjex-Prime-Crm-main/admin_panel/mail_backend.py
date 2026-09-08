"""SMTP backend that verifies TLS using Mozilla CA bundle from certifi.

Falls back to Django's default (system CAs) if certifi is not installed.
Useful on minimal servers where the OS CA store is empty or outdated.
"""

from __future__ import annotations

import ssl

from django.core.mail.backends.smtp import EmailBackend
from django.utils.functional import cached_property

try:
    import certifi

    _CERTIFI_CA = certifi.where()
except ImportError:
    _CERTIFI_CA = None


class CertifiEmailBackend(EmailBackend):
    """Same as Django's SMTP backend, but default verify paths use certifi's CA file."""

    @cached_property
    def ssl_context(self):
        if self.ssl_certfile or self.ssl_keyfile:
            return super().ssl_context
        if _CERTIFI_CA:
            return ssl.create_default_context(cafile=_CERTIFI_CA)
        return ssl.create_default_context()
