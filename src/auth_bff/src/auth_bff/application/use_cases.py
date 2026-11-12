"""Login, refresh and logout. They only orchestrate the identity provider port."""

from auth_bff.application.ports import IdentityProvider
from auth_bff.domain.errors import (
    AuthError,
    InvalidRequestError,
    RevocationFailedError,
    SessionExpiredError,
)
from auth_bff.domain.session import SESSION_LIFETIME_SECONDS, AuthOutcome, CookieAction


class Login:
    """Sign in and ask for the refresh token cookie to be set, with a fixed lifetime."""

    def __init__(self, identity_provider: IdentityProvider) -> None:
        self._identity_provider = identity_provider

    def execute(self, username: str, password: str) -> AuthOutcome:
        if not username or not password:
            return AuthOutcome(cookie=CookieAction.KEEP, error=InvalidRequestError())
        try:
            result = self._identity_provider.sign_in(username, password)
        except AuthError as error:
            return AuthOutcome(cookie=CookieAction.KEEP, error=error)
        return AuthOutcome(
            cookie=CookieAction.SET,
            tokens=result.tokens,
            refresh_token=result.refresh_token,
            cookie_max_age=SESSION_LIFETIME_SECONDS,
        )


class Refresh:
    """Renew the tokens. The cookie is never set again, so the session ends 24 hours after login."""

    def __init__(self, identity_provider: IdentityProvider) -> None:
        self._identity_provider = identity_provider

    def execute(self, refresh_token: str | None) -> AuthOutcome:
        if not refresh_token:
            return AuthOutcome(cookie=CookieAction.CLEAR, error=SessionExpiredError())
        try:
            tokens = self._identity_provider.renew(refresh_token)
        except SessionExpiredError as error:
            return AuthOutcome(cookie=CookieAction.CLEAR, error=error)
        except AuthError as error:
            return AuthOutcome(cookie=CookieAction.KEEP, error=error)
        return AuthOutcome(cookie=CookieAction.KEEP, tokens=tokens)


class Logout:
    """Revoke the refresh token and always clear the cookie."""

    def __init__(self, identity_provider: IdentityProvider) -> None:
        self._identity_provider = identity_provider

    def execute(self, refresh_token: str | None) -> AuthOutcome:
        if not refresh_token:
            return AuthOutcome(cookie=CookieAction.CLEAR)
        try:
            self._identity_provider.revoke(refresh_token)
        except RevocationFailedError as error:
            return AuthOutcome(cookie=CookieAction.CLEAR, error=error)
        return AuthOutcome(cookie=CookieAction.CLEAR)
