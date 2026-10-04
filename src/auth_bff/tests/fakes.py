"""In-memory fakes shared by the tests."""

from typing import Any

import boto3

from auth_bff.domain.errors import AuthError
from auth_bff.domain.session import SignInResult, Tokens

TOKENS = Tokens(id_token="id-token", access_token="access-token", expires_in=3600)
REFRESH_TOKEN = "refresh-token"


class FakeIdentityProvider:
    """Identity provider that records calls and fails with the configured error."""

    def __init__(self, error: AuthError | None = None) -> None:
        self.error = error
        self.calls: list[tuple[str, tuple[str, ...]]] = []

    def sign_in(self, username: str, password: str) -> SignInResult:
        self.calls.append(("sign_in", (username, password)))
        if self.error:
            raise self.error
        return SignInResult(tokens=TOKENS, refresh_token=REFRESH_TOKEN)

    def renew(self, refresh_token: str) -> Tokens:
        self.calls.append(("renew", (refresh_token,)))
        if self.error:
            raise self.error
        return TOKENS

    def revoke(self, refresh_token: str) -> None:
        self.calls.append(("revoke", (refresh_token,)))
        if self.error:
            raise self.error


def fake_credentials_client(service: str) -> Any:
    """A signed client with dummy credentials, to be used with the botocore Stubber."""
    return boto3.client(
        service,
        region_name="us-east-2",
        aws_access_key_id="test",
        aws_secret_access_key="test",
    )
