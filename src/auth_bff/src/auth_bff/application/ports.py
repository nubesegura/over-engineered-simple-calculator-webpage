"""Ports: what the use cases need from the outside and what the entrypoint needs from them."""

from dataclasses import dataclass
from typing import Protocol

from auth_bff.domain.session import AuthOutcome, SignInResult, Tokens


class IdentityProvider(Protocol):
    """Identity provider operations. Failures are raised as ``AuthError`` subclasses."""

    def sign_in(self, username: str, password: str) -> SignInResult: ...

    def renew(self, refresh_token: str) -> Tokens: ...

    def revoke(self, refresh_token: str) -> None: ...


class SecretUnavailableError(Exception):
    """A secret could not be read. The message is only the failure type, never a value."""


class SecretReader(Protocol):
    """Reads a secret by name. Failures are raised as ``SecretUnavailableError``."""

    def read(self, name: str) -> str: ...


class LoginUseCase(Protocol):
    def execute(self, username: str, password: str) -> AuthOutcome: ...


class RefreshUseCase(Protocol):
    def execute(self, refresh_token: str | None) -> AuthOutcome: ...


class LogoutUseCase(Protocol):
    def execute(self, refresh_token: str | None) -> AuthOutcome: ...


@dataclass(frozen=True)
class RequestRecord:
    """One line of the request log. It never holds secrets or the username."""

    endpoint: str
    status: int
    outcome: str
    request_id: str
    error_type: str | None = None
    username_hash: str | None = None


class RequestLog(Protocol):
    def record(self, record: RequestRecord) -> None: ...
