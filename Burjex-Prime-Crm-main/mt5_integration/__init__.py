"""
MetaTrader 5 Web API integration for Burjex Prime CRM.

This package implements the MT5 Manager Web API protocol exactly as documented
in the MetaTrader 5 SDK (Examples/Web/PHP/mt5_api/).

Protocol summary
----------------
- TCP socket to MT5 server (default port 443)
- 9-byte packet header:  4 hex chars (body size) + 4 hex chars (seq number) + 1 hex char (flag)
- First packet prefix:   "MT5WEBAPI{size:04x}{seq:04x}"
- Subsequent packets:    "{size:04x}{seq:04x}"
- Body is UTF-16LE encoded; commands are pipe-delimited key=value pairs
- Authentication uses MD5 challenge-response (AUTH_START → AUTH_ANSWER)
- Optional AES-256-OFB stream cipher for encryption after auth

Configuration (environment variables or Django settings)
---------------------------------------------------------
MT5_SERVER_HOST   - MT5 server hostname/IP
MT5_SERVER_PORT   - MT5 server port (default 443)
MT5_MANAGER_LOGIN - Manager login (integer)
MT5_MANAGER_PASS  - Manager password (plain text)
MT5_CONNECT_TIMEOUT - Connection timeout in seconds (default 10)
MT5_SYNC_INTERVAL_SECONDS - Celery beat sync interval (default 60)
"""

from mt5_integration.client import MT5Client, MT5ConnectionError, MT5AuthError, MT5APIError

__all__ = ["MT5Client", "MT5ConnectionError", "MT5AuthError", "MT5APIError"]
