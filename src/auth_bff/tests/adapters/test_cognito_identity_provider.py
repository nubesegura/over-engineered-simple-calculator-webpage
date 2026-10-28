import base64
import hashlib
import hmac
from collections.abc import Iterator
from typing import Any

import pytest
from botocore import UNSIGNED
from botocore.exceptions import ConnectTimeoutError, EndpointConnectionError
from botocore.stub import Stubber

from auth_bff.adapters.outbound.cognito_identity_provider import (
    CognitoIdentityProvider,
    create_cognito_client,
)
from auth_bff.domain.errors import (
    AuthError,
    ChallengeRequiredError,
    IdentityProviderUnavailableError,
    InvalidCredentialsError,
    RevocationFailedError,
    SessionExpiredError,
    TooManyAttemptsError,
)

CLIENT_ID = "test-client-id"
CLIENT_SECRET = "test-client-secret-0123456789abcdef"
COGNITO_MESSAGE = "SECRET-COGNITO-MESSAGE user@example.com"

Stubbed = tuple[CognitoIdentityProvider, Stubber]


def _secret_hash(username: str) -> str:
    digest = hmac.new(
        CLIENT_SECRET.encode(), (username + CLIENT_ID).encode(), hashlib.sha256
    ).digest()
    return base64.b64encode(digest).decode()


@pytest.fixture
def stubbed() -> Iterator[Stubbed]:
    client = create_cognito_client("us-east-2")
    with Stubber(client) as stubber:
        yield CognitoIdentityProvider(client, CLIENT_ID, CLIENT_SECRET), stubber
        stubber.assert_no_pending_responses()


def _client_error(stubber: Stubber, operation: str, code: str) -> None:
    stubber.add_client_error(
        operation, service_error_code=code, service_message=COGNITO_MESSAGE, http_status_code=400
    )


def _assert_clean(error: AuthError) -> None:
    assert COGNITO_MESSAGE not in str(error)
    assert COGNITO_MESSAGE not in repr(error)
    assert error.__cause__ is None
    assert error.__suppress_context__


def test_client_is_unsigned_with_short_timeouts_and_one_retry() -> None:
    client = create_cognito_client("us-east-2")

    config = client.meta.config
    assert config.signature_version is UNSIGNED
    assert config.connect_timeout == 2
    assert config.read_timeout == 5
    assert config.retries["total_max_attempts"] == 2
    assert client.meta.region_name == "us-east-2"


def test_sign_in_uses_user_password_auth_and_returns_all_tokens(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response(
        "initiate_auth",
        {
            "AuthenticationResult": {
                "IdToken": "id",
                "AccessToken": "access",
                "RefreshToken": "refresh",
                "ExpiresIn": 3600,
                "TokenType": "Bearer",
            }
        },
        {
            "ClientId": CLIENT_ID,
            "AuthFlow": "USER_PASSWORD_AUTH",
            "AuthParameters": {
                "USERNAME": "user@example.com",
                "PASSWORD": "pw",
                "SECRET_HASH": _secret_hash("user@example.com"),
            },
        },
    )

    result = provider.sign_in("user@example.com", "pw")

    assert (result.tokens.id_token, result.tokens.access_token) == ("id", "access")
    assert result.tokens.expires_in == 3600
    assert result.refresh_token == "refresh"


def test_sign_in_challenge_is_challenge_required(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response(
        "initiate_auth", {"ChallengeName": "NEW_PASSWORD_REQUIRED", "Session": "s" * 20}
    )

    with pytest.raises(ChallengeRequiredError) as caught:
        provider.sign_in("user", "pw")

    assert caught.value.provider_error_type == "NEW_PASSWORD_REQUIRED"


def test_sign_in_without_authentication_result_is_unavailable(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response("initiate_auth", {})

    with pytest.raises(IdentityProviderUnavailableError):
        provider.sign_in("user", "pw")


def test_sign_in_without_refresh_token_is_unavailable(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response(
        "initiate_auth",
        {"AuthenticationResult": {"IdToken": "id", "AccessToken": "access", "ExpiresIn": 3600}},
    )

    with pytest.raises(IdentityProviderUnavailableError):
        provider.sign_in("user", "pw")


def test_sign_in_with_incomplete_tokens_is_unavailable(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response(
        "initiate_auth",
        {"AuthenticationResult": {"IdToken": "id", "RefreshToken": "refresh", "ExpiresIn": 1}},
    )

    with pytest.raises(IdentityProviderUnavailableError):
        provider.sign_in("user", "pw")


@pytest.mark.parametrize(
    ("code", "expected"),
    [
        ("NotAuthorizedException", InvalidCredentialsError),
        ("UserNotFoundException", InvalidCredentialsError),
        ("UserNotConfirmedException", InvalidCredentialsError),
        ("PasswordResetRequiredException", ChallengeRequiredError),
        ("TooManyRequestsException", TooManyAttemptsError),
        ("LimitExceededException", TooManyAttemptsError),
        ("InternalErrorException", IdentityProviderUnavailableError),
        ("InvalidParameterException", IdentityProviderUnavailableError),
    ],
)
def test_sign_in_error_mapping_never_leaks_the_provider_message(
    stubbed: Stubbed, code: str, expected: type[AuthError]
) -> None:
    provider, stubber = stubbed
    _client_error(stubber, "initiate_auth", code)

    with pytest.raises(expected) as caught:
        provider.sign_in("user", "pw")

    assert type(caught.value) is expected
    assert caught.value.provider_error_type == code
    _assert_clean(caught.value)


def test_renew_uses_get_tokens_from_refresh_token_with_the_client_secret(
    stubbed: Stubbed,
) -> None:
    provider, stubber = stubbed
    stubber.add_response(
        "get_tokens_from_refresh_token",
        {"AuthenticationResult": {"IdToken": "id2", "AccessToken": "access2", "ExpiresIn": 1800}},
        {"ClientId": CLIENT_ID, "ClientSecret": CLIENT_SECRET, "RefreshToken": "refresh"},
    )

    tokens = provider.renew("refresh")

    assert (tokens.id_token, tokens.access_token, tokens.expires_in) == ("id2", "access2", 1800)


def test_renew_ignores_a_refresh_token_in_the_result(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response(
        "get_tokens_from_refresh_token",
        {
            "AuthenticationResult": {
                "IdToken": "id2",
                "AccessToken": "access2",
                "RefreshToken": "rotated",
                "ExpiresIn": 1800,
            }
        },
    )

    tokens = provider.renew("refresh")

    assert "rotated" not in repr(tokens)


@pytest.mark.parametrize(
    ("code", "expected"),
    [
        ("NotAuthorizedException", SessionExpiredError),
        ("UserNotFoundException", SessionExpiredError),
        ("PasswordResetRequiredException", SessionExpiredError),
        ("InvalidParameterException", SessionExpiredError),
        ("RefreshTokenReuseException", SessionExpiredError),
        ("TooManyRequestsException", TooManyAttemptsError),
        ("InternalErrorException", IdentityProviderUnavailableError),
    ],
)
def test_renew_error_mapping_never_leaks_the_provider_message(
    stubbed: Stubbed, code: str, expected: type[AuthError]
) -> None:
    provider, stubber = stubbed
    _client_error(stubber, "get_tokens_from_refresh_token", code)

    with pytest.raises(expected) as caught:
        provider.renew("refresh")

    assert type(caught.value) is expected
    _assert_clean(caught.value)


def test_renew_without_authentication_result_is_unavailable(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response("get_tokens_from_refresh_token", {})

    with pytest.raises(IdentityProviderUnavailableError):
        provider.renew("refresh")


def test_revoke_calls_revoke_token(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    stubber.add_response(
        "revoke_token",
        {},
        {"ClientId": CLIENT_ID, "ClientSecret": CLIENT_SECRET, "Token": "refresh"},
    )

    provider.revoke("refresh")


@pytest.mark.parametrize(
    "code", ["InvalidParameterException", "TooManyRequestsException", "InternalErrorException"]
)
def test_revoke_failures_are_revocation_failed(stubbed: Stubbed, code: str) -> None:
    provider, stubber = stubbed
    _client_error(stubber, "revoke_token", code)

    with pytest.raises(RevocationFailedError) as caught:
        provider.revoke("refresh")

    assert caught.value.provider_error_type == code
    _assert_clean(caught.value)


class _BrokenClient:
    """Client whose calls fail like a network problem."""

    def __init__(self, error: Exception) -> None:
        self._error = error

    def initiate_auth(self, **_: Any) -> dict[str, Any]:
        raise self._error

    def get_tokens_from_refresh_token(self, **_: Any) -> dict[str, Any]:
        raise self._error

    def revoke_token(self, **_: Any) -> dict[str, Any]:
        raise self._error


@pytest.mark.parametrize(
    "network_error",
    [
        ConnectTimeoutError(endpoint_url="https://cognito-idp.example"),
        EndpointConnectionError(endpoint_url="https://cognito-idp.example"),
    ],
)
def test_network_errors_are_unavailable_or_revocation_failed(network_error: Exception) -> None:
    provider = CognitoIdentityProvider(_BrokenClient(network_error), CLIENT_ID, CLIENT_SECRET)

    with pytest.raises(IdentityProviderUnavailableError) as sign_in_error:
        provider.sign_in("user", "pw")
    with pytest.raises(IdentityProviderUnavailableError):
        provider.renew("refresh")
    with pytest.raises(RevocationFailedError):
        provider.revoke("refresh")

    assert sign_in_error.value.provider_error_type == type(network_error).__name__


def test_an_oversize_or_malformed_refresh_token_is_an_expired_session() -> None:
    client = create_cognito_client("us-east-2")
    provider = CognitoIdentityProvider(client, CLIENT_ID, CLIENT_SECRET)

    with pytest.raises(SessionExpiredError) as caught:
        provider.renew(12345)  # type: ignore[arg-type]

    assert caught.value.provider_error_type == "ParamValidationError"
    _assert_clean(caught.value)


def test_the_secret_and_the_hash_never_appear_in_errors_or_their_text(stubbed: Stubbed) -> None:
    provider, stubber = stubbed
    _client_error(stubber, "initiate_auth", "NotAuthorizedException")
    _client_error(stubber, "get_tokens_from_refresh_token", "NotAuthorizedException")
    _client_error(stubber, "revoke_token", "InternalErrorException")
    texts: list[str] = []

    for call in (
        lambda: provider.sign_in("user@example.com", "pw"),
        lambda: provider.renew("refresh"),
        lambda: provider.revoke("refresh"),
    ):
        with pytest.raises(AuthError) as caught:
            call()
        texts.extend([str(caught.value), repr(caught.value), repr(caught.value.__dict__)])

    for text in texts:
        assert CLIENT_SECRET not in text
        assert _secret_hash("user@example.com") not in text
    assert CLIENT_SECRET not in repr(provider)
