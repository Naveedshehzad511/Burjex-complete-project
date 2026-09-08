"""DRF exception handler that matches the CRM JSON envelope."""

from __future__ import annotations

from typing import Any

from rest_framework import status
from rest_framework.exceptions import AuthenticationFailed, NotAuthenticated, PermissionDenied, ValidationError
from rest_framework.response import Response
from rest_framework.views import exception_handler as drf_exception_handler


def crm_exception_handler(exc, context) -> Response | None:
    response = drf_exception_handler(exc, context)

    if response is None:
        return None

    message = "An error occurred."
    errors: Any = None

    if isinstance(exc, NotAuthenticated):
        message = "Authentication required."
    elif isinstance(exc, AuthenticationFailed):
        message = str(exc.detail) if exc.detail else "Authentication failed."
    elif isinstance(exc, PermissionDenied):
        message = str(exc.detail) if exc.detail else "You do not have permission to perform this action."
    elif isinstance(exc, ValidationError):
        message = "Validation failed."
        errors = response.data
    elif isinstance(response.data, dict):
        detail = response.data.get("detail")
        if detail is not None:
            message = str(detail)
        else:
            errors = response.data
            if response.status_code == status.HTTP_400_BAD_REQUEST:
                message = "Validation failed."
    elif isinstance(response.data, list):
        errors = response.data
        message = str(response.data[0]) if response.data else message
    else:
        message = str(response.data)

    body: dict[str, Any] = {
        "success": False,
        "message": message,
    }
    if errors is not None:
        body["errors"] = errors

    response.data = body
    return response
