"""Values exchanged between the use cases and the adapters."""

from dataclasses import dataclass
from enum import Enum

from auth_bff.domain.errors import AuthError

SESSION_LIFETIME_SECONDS = 86400


class CookieAction(Enum):
    """What the response must do with the refresh token cookie."""

    SET = "set"
    KEEP = "keep"
    CLEAR = "clear"


@dataclass(frozen=True)
class Tokens:
    """Short-lived tokens returned to the page."""

    id_token: str
    access_token: str
    expires_in: int


@dataclass(frozen=True)
class SignInResult:
    """Tokens of a sign-in plus the refresh token that only travels in the cookie."""

    tokens: Tokens
    refresh_token: str


@dataclass(frozen=True)
class AuthOutcome:
    """Result of a use case: tokens or an error, and what to do with the cookie."""

    cookie: CookieAction
    tokens: Tokens | None = None
    refresh_token: str | None = None
    cookie_max_age: int | None = None
    error: AuthError | None = None
