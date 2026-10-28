"""The refresh token cookie: name, attributes, reading and the Set-Cookie values."""

import re
from collections.abc import Iterable

from auth_bff.domain.errors import IdentityProviderUnavailableError
from auth_bff.domain.session import AuthOutcome, CookieAction

COOKIE_NAME = "__Secure-oecalc-refresh"
_ATTRIBUTES = "HttpOnly; Secure; SameSite=Strict; Path=/auth"
MAX_TOKEN_LENGTH = 4096
# Base64 and base64url characters, dot and equals: no ";", CR, LF, space, comma or quote.
_TOKEN = re.compile(r"[A-Za-z0-9._~+/=-]+")


def _is_valid_token(value: str) -> bool:
    return len(value) <= MAX_TOKEN_LENGTH and _TOKEN.fullmatch(value) is not None


def set_cookie(value: str, max_age: int) -> str:
    """Build a ``Set-Cookie`` value; a value that could inject attributes or headers is refused."""
    if not _is_valid_token(value):
        raise IdentityProviderUnavailableError("InvalidCookieValue")
    return f"{COOKIE_NAME}={value}; Max-Age={max_age}; {_ATTRIBUTES}"


def clear_cookie() -> str:
    return f"{COOKIE_NAME}=; Max-Age=0; {_ATTRIBUTES}"


def read_refresh_token(cookie_headers: Iterable[str]) -> str | None:
    """Return the refresh token from ``Cookie`` header values (``a=1; b=2``), if present.

    An oversize value or one with unexpected characters counts as absent.
    """
    for header in cookie_headers:
        for pair in header.split(";"):
            name, separator, value = pair.strip().partition("=")
            if separator and name == COOKIE_NAME:
                return value if _is_valid_token(value) else None
    return None


def set_cookie_values(outcome: AuthOutcome) -> list[str]:
    """Return the ``Set-Cookie`` values for an outcome; refresh and failed logins send none."""
    if outcome.cookie is CookieAction.SET and outcome.refresh_token is not None:
        return [set_cookie(outcome.refresh_token, outcome.cookie_max_age or 0)]
    if outcome.cookie is CookieAction.CLEAR:
        return [clear_cookie()]
    return []
