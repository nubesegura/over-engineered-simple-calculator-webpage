"""Amazon Cognito implementation of the identity provider port.

The calls are public operations of the user pool, so the client is created without
credentials (unsigned). The app client has a secret that only this adapter holds, in memory:
sign-in sends a ``SECRET_HASH`` and renewal and revocation send the secret as a parameter.
The secret and the hash are never logged and never put in an error.
"""

import base64
import hashlib
import hmac
from collections.abc import Callable
from typing import Any

import boto3
from botocore import UNSIGNED
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError, ParamValidationError

from auth_bff.domain.errors import (
    AuthError,
    ChallengeRequiredError,
    IdentityProviderUnavailableError,
    InvalidCredentialsError,
    RevocationFailedError,
    SessionExpiredError,
    TooManyAttemptsError,
)
from auth_bff.domain.session import SignInResult, Tokens

_CONNECT_TIMEOUT_SECONDS = 2
_READ_TIMEOUT_SECONDS = 5
_TOTAL_ATTEMPTS = 2

_THROTTLING = frozenset({"TooManyRequestsException", "LimitExceededException"})
_REJECTED = frozenset(
    {"NotAuthorizedException", "UserNotFoundException", "UserNotConfirmedException"}
)
_RESET_REQUIRED = "PasswordResetRequiredException"
_INVALID_PARAMETER = "InvalidParameterException"
_REUSE_DETECTED = "RefreshTokenReuseException"

type _ProviderFailure = ClientError | BotoCoreError


def create_cognito_client(region: str) -> Any:
    """Build the ``cognito-idp`` client: unsigned, short timeouts, at most one retry."""
    config = Config(
        signature_version=UNSIGNED,
        connect_timeout=_CONNECT_TIMEOUT_SECONDS,
        read_timeout=_READ_TIMEOUT_SECONDS,
        retries={"total_max_attempts": _TOTAL_ATTEMPTS, "mode": "standard"},
    )
    return boto3.client("cognito-idp", region_name=region, config=config)


def _error_type(error: _ProviderFailure) -> str:
    if isinstance(error, ClientError):
        return str(error.response.get("Error", {}).get("Code", "ClientError"))
    return type(error).__name__


def _sign_in_error(error: _ProviderFailure) -> AuthError:
    error_type = _error_type(error)
    if error_type in _REJECTED:
        return InvalidCredentialsError(error_type)
    if error_type == _RESET_REQUIRED:
        return ChallengeRequiredError(error_type)
    if error_type in _THROTTLING:
        return TooManyAttemptsError(error_type)
    return IdentityProviderUnavailableError(error_type)


def _renew_error(error: _ProviderFailure) -> AuthError:
    error_type = _error_type(error)
    expired = {_RESET_REQUIRED, _INVALID_PARAMETER, _REUSE_DETECTED}
    if error_type in _REJECTED or error_type in expired or isinstance(error, ParamValidationError):
        return SessionExpiredError(error_type)
    if error_type in _THROTTLING:
        return TooManyAttemptsError(error_type)
    return IdentityProviderUnavailableError(error_type)


def _authentication_result(response: dict[str, Any]) -> dict[str, Any]:
    result = response.get("AuthenticationResult")
    if not isinstance(result, dict):
        raise IdentityProviderUnavailableError("MissingAuthenticationResult")
    return result


def _tokens(result: dict[str, Any]) -> Tokens:
    try:
        return Tokens(
            id_token=str(result["IdToken"]),
            access_token=str(result["AccessToken"]),
            expires_in=int(result["ExpiresIn"]),
        )
    except (KeyError, ValueError):
        raise IdentityProviderUnavailableError("MalformedAuthenticationResult") from None


class CognitoIdentityProvider:
    """Sign in, renew and revoke against a Cognito user pool app client."""

    def __init__(self, client: Any, app_client_id: str, client_secret: str) -> None:
        self._client = client
        self._app_client_id = app_client_id
        self._client_secret = client_secret

    def _secret_hash(self, username: str) -> str:
        message = (username + self._app_client_id).encode("utf-8")
        digest = hmac.new(self._client_secret.encode("utf-8"), message, hashlib.sha256).digest()
        return base64.b64encode(digest).decode("ascii")

    def sign_in(self, username: str, password: str) -> SignInResult:
        parameters = {
            "USERNAME": username,
            "PASSWORD": password,
            "SECRET_HASH": self._secret_hash(username),
        }
        response = self._call(
            self._client.initiate_auth,
            _sign_in_error,
            ClientId=self._app_client_id,
            AuthFlow="USER_PASSWORD_AUTH",
            AuthParameters=parameters,
        )
        challenge = response.get("ChallengeName")
        if challenge:
            raise ChallengeRequiredError(str(challenge))
        result = _authentication_result(response)
        refresh_token = result.get("RefreshToken")
        if not refresh_token:
            raise IdentityProviderUnavailableError("MalformedAuthenticationResult")
        return SignInResult(tokens=_tokens(result), refresh_token=str(refresh_token))

    def renew(self, refresh_token: str) -> Tokens:
        response = self._call(
            self._client.get_tokens_from_refresh_token,
            _renew_error,
            ClientId=self._app_client_id,
            ClientSecret=self._client_secret,
            RefreshToken=refresh_token,
        )
        return _tokens(_authentication_result(response))

    def revoke(self, refresh_token: str) -> None:
        try:
            self._client.revoke_token(
                ClientId=self._app_client_id,
                ClientSecret=self._client_secret,
                Token=refresh_token,
            )
        except (ClientError, BotoCoreError) as error:
            raise RevocationFailedError(_error_type(error)) from None

    @staticmethod
    def _call(
        operation: Callable[..., dict[str, Any]],
        map_error: Callable[[_ProviderFailure], AuthError],
        **arguments: Any,
    ) -> dict[str, Any]:
        try:
            return operation(**arguments)
        except (ClientError, BotoCoreError) as error:
            raise map_error(error) from None
