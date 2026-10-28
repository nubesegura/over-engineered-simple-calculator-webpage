"""Function URL responses (payload format 2.0) and the HTTP mapping of the error taxonomy.

The BFF never answers 403 or 404: CloudFront turns both into the app page.
"""

import json
from typing import Any

from auth_bff.domain.errors import (
    AuthError,
    ChallengeRequiredError,
    IdentityProviderUnavailableError,
    InternalError,
    InvalidCredentialsError,
    InvalidRequestError,
    RevocationFailedError,
    SessionExpiredError,
    TooManyAttemptsError,
)
from auth_bff.domain.session import Tokens

_STATUS_AND_MESSAGE: dict[type[AuthError], tuple[int, str]] = {
    InvalidRequestError: (400, "The request is not valid."),
    InvalidCredentialsError: (401, "The username or password is incorrect."),
    ChallengeRequiredError: (
        409,
        "This account needs an extra step that this page does not support. "
        "Contact the administrator.",
    ),
    TooManyAttemptsError: (429, "Too many attempts. Wait a few minutes and try again."),
    IdentityProviderUnavailableError: (
        503,
        "The sign-in service is temporarily unavailable. Try again shortly.",
    ),
    SessionExpiredError: (401, "Your session has expired. Please log in again."),
    InternalError: (500, "Something went wrong. Try again shortly."),
    RevocationFailedError: (502, "You were logged out here, but the session could not be revoked."),
}
_FALLBACK = InvalidRequestError

Response = dict[str, Any]


def _build(status: int, body: dict[str, Any] | None, cookies: list[str]) -> Response:
    headers = {"Cache-Control": "no-store"}
    response: Response = {"statusCode": status, "headers": headers}
    if body is not None:
        headers["Content-Type"] = "application/json"
        response["body"] = json.dumps(body, separators=(",", ":"))
    if cookies:
        response["cookies"] = cookies
    return response


def tokens_response(tokens: Tokens, cookies: list[str]) -> Response:
    body = {
        "id_token": tokens.id_token,
        "access_token": tokens.access_token,
        "expires_in": tokens.expires_in,
    }
    return _build(200, body, cookies)


def no_content_response(cookies: list[str]) -> Response:
    return _build(204, None, cookies)


def error_response(error: AuthError, request_id: str, cookies: list[str]) -> Response:
    status, message = _STATUS_AND_MESSAGE.get(type(error), _STATUS_AND_MESSAGE[_FALLBACK])
    body = {"error": {"code": error.code, "message": message, "request_id": request_id}}
    return _build(status, body, cookies)
