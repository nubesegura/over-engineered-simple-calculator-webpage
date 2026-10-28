"""Error taxonomy of the BFF. HTTP status codes and messages live in the inbound adapter."""

from typing import ClassVar


class AuthError(Exception):
    """Base class of every expected failure.

    ``provider_error_type`` is the error type reported by the identity provider (for example
    ``NotAuthorizedException``). It is meant for logs only and never carries a provider message.
    """

    code: ClassVar[str] = "auth_error"

    def __init__(self, provider_error_type: str | None = None) -> None:
        super().__init__(self.code)
        self.provider_error_type = provider_error_type


class InvalidRequestError(AuthError):
    """The request is malformed or rejected before reaching the identity provider."""

    code = "invalid_request"


class InvalidCredentialsError(AuthError):
    """Wrong password, unknown user or disabled user (never told apart)."""

    code = "invalid_credentials"


class ChallengeRequiredError(AuthError):
    """The identity provider asks for a step this application does not support."""

    code = "challenge_required"


class TooManyAttemptsError(AuthError):
    """The identity provider is throttling or temporarily blocking the user."""

    code = "too_many_attempts"


class IdentityProviderUnavailableError(AuthError):
    """The identity provider cannot be reached or failed."""

    code = "identity_provider_unavailable"


class SessionExpiredError(AuthError):
    """The refresh token is missing, expired or revoked."""

    code = "session_expired"


class RevocationFailedError(AuthError):
    """The identity provider could not revoke the refresh token."""

    code = "revocation_failed"


class InternalError(AuthError):
    """An unexpected failure inside the BFF. Nothing about it reaches the caller."""

    code = "internal_error"
