import pytest

from auth_bff.application.use_cases import Login, Logout, Refresh
from auth_bff.domain.errors import (
    AuthError,
    ChallengeRequiredError,
    IdentityProviderUnavailableError,
    InvalidCredentialsError,
    InvalidRequestError,
    RevocationFailedError,
    SessionExpiredError,
    TooManyAttemptsError,
)
from auth_bff.domain.session import SESSION_LIFETIME_SECONDS, CookieAction
from tests.fakes import REFRESH_TOKEN, TOKENS, FakeIdentityProvider


def test_login_success_sets_exactly_one_cookie_with_the_session_lifetime() -> None:
    provider = FakeIdentityProvider()

    outcome = Login(provider).execute("user@example.com", "secret")

    assert outcome.error is None
    assert outcome.tokens == TOKENS
    assert outcome.cookie is CookieAction.SET
    assert outcome.refresh_token == REFRESH_TOKEN
    assert outcome.cookie_max_age == SESSION_LIFETIME_SECONDS == 86400
    assert provider.calls == [("sign_in", ("user@example.com", "secret"))]


@pytest.mark.parametrize(("username", "password"), [("", "secret"), ("user", ""), ("", "")])
def test_login_with_an_empty_field_is_invalid_and_never_calls_the_provider(
    username: str, password: str
) -> None:
    provider = FakeIdentityProvider()

    outcome = Login(provider).execute(username, password)

    assert isinstance(outcome.error, InvalidRequestError)
    assert outcome.cookie is CookieAction.KEEP
    assert outcome.tokens is None
    assert provider.calls == []


@pytest.mark.parametrize(
    "error",
    [
        InvalidCredentialsError(),
        ChallengeRequiredError(),
        TooManyAttemptsError(),
        IdentityProviderUnavailableError(),
    ],
)
def test_login_failure_returns_the_error_and_sets_no_cookie(error: AuthError) -> None:
    outcome = Login(FakeIdentityProvider(error)).execute("user", "secret")

    assert outcome.error is error
    assert outcome.cookie is CookieAction.KEEP
    assert outcome.refresh_token is None
    assert outcome.tokens is None


def test_refresh_success_returns_tokens_and_leaves_the_cookie_alone() -> None:
    provider = FakeIdentityProvider()

    outcome = Refresh(provider).execute(REFRESH_TOKEN)

    assert outcome.error is None
    assert outcome.tokens == TOKENS
    assert outcome.cookie is CookieAction.KEEP
    assert outcome.refresh_token is None
    assert provider.calls == [("renew", (REFRESH_TOKEN,))]


@pytest.mark.parametrize("cookie_value", [None, ""])
def test_refresh_without_a_token_clears_the_cookie_and_skips_the_provider(
    cookie_value: str | None,
) -> None:
    provider = FakeIdentityProvider()

    outcome = Refresh(provider).execute(cookie_value)

    assert isinstance(outcome.error, SessionExpiredError)
    assert outcome.cookie is CookieAction.CLEAR
    assert provider.calls == []


def test_refresh_unauthorized_clears_the_cookie() -> None:
    outcome = Refresh(FakeIdentityProvider(SessionExpiredError())).execute(REFRESH_TOKEN)

    assert isinstance(outcome.error, SessionExpiredError)
    assert outcome.cookie is CookieAction.CLEAR


@pytest.mark.parametrize("error", [IdentityProviderUnavailableError(), TooManyAttemptsError()])
def test_refresh_unavailable_keeps_the_cookie_so_the_page_can_retry(error: AuthError) -> None:
    outcome = Refresh(FakeIdentityProvider(error)).execute(REFRESH_TOKEN)

    assert outcome.error is error
    assert outcome.cookie is CookieAction.KEEP


def test_logout_revokes_the_token_and_clears_the_cookie() -> None:
    provider = FakeIdentityProvider()

    outcome = Logout(provider).execute(REFRESH_TOKEN)

    assert outcome.error is None
    assert outcome.cookie is CookieAction.CLEAR
    assert provider.calls == [("revoke", (REFRESH_TOKEN,))]


@pytest.mark.parametrize("cookie_value", [None, ""])
def test_logout_without_a_token_still_clears_the_cookie(cookie_value: str | None) -> None:
    provider = FakeIdentityProvider()

    outcome = Logout(provider).execute(cookie_value)

    assert outcome.error is None
    assert outcome.cookie is CookieAction.CLEAR
    assert provider.calls == []


def test_logout_clears_the_cookie_even_when_revoke_fails_and_reports_the_failure() -> None:
    error = RevocationFailedError()

    outcome = Logout(FakeIdentityProvider(error)).execute(REFRESH_TOKEN)

    assert outcome.error is error
    assert outcome.cookie is CookieAction.CLEAR
