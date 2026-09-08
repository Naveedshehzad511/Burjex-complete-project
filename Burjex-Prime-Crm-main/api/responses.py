"""Consistent JSON envelope for all /api/v1/ responses."""

from __future__ import annotations

from typing import Any

from rest_framework.response import Response


def success_response(
    data: Any = None,
    message: str = "Operation completed successfully.",
    status: int = 200,
    **extra,
) -> Response:
    body: dict[str, Any] = {
        "success": True,
        "message": message,
        "data": {} if data is None else data,
    }
    if extra:
        body.update(extra)
    return Response(body, status=status)


def error_response(
    message: str = "An error occurred.",
    *,
    errors: dict | list | None = None,
    status: int = 400,
    data: Any = None,
    **extra,
) -> Response:
    body: dict[str, Any] = {
        "success": False,
        "message": message,
    }
    if errors is not None:
        body["errors"] = errors
    if data is not None:
        body["data"] = data
    if extra:
        body.update(extra)
    return Response(body, status=status)


def validation_error_response(errors: dict | list, message: str = "Validation failed.") -> Response:
    return error_response(message, errors=errors, status=400)


def auth_error_response(message: str = "Authentication required.") -> Response:
    return error_response(message, status=401)


def permission_error_response(message: str = "You do not have permission to perform this action.") -> Response:
    return error_response(message, status=403)


def not_found_response(message: str = "Resource not found.") -> Response:
    return error_response(message, status=404)
