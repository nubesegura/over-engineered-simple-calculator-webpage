"""Composition root: the only place where adapters are chosen and wired."""

from collections.abc import Mapping
from functools import cached_property

from auth_bff.adapters.inbound.function_url import FunctionUrlAdapter
from auth_bff.adapters.outbound.cognito_identity_provider import (
    CognitoIdentityProvider,
    create_cognito_client,
)
from auth_bff.adapters.outbound.ssm_secret_reader import SsmSecretReader, create_ssm_client
from auth_bff.application.ports import IdentityProvider, SecretReader, SecretUnavailableError
from auth_bff.application.use_cases import Login, Logout, Refresh
from auth_bff.config.logging import JsonRequestLog, configure_logging
from auth_bff.config.settings import ConfigurationError, Settings, load_settings


class Container:
    """The adapters, built once per cold start."""

    def __init__(self, settings: Settings, identity_provider: IdentityProvider) -> None:
        self.settings = settings
        self.identity_provider = identity_provider

    @cached_property
    def function_url(self) -> FunctionUrlAdapter:
        return FunctionUrlAdapter(
            login=Login(self.identity_provider),
            refresh=Refresh(self.identity_provider),
            logout=Logout(self.identity_provider),
            request_log=JsonRequestLog(),
            allowed_origin=self.settings.allowed_origin,
        )


def _read_client_secret(settings: Settings) -> str:
    reader: SecretReader = SsmSecretReader(create_ssm_client(settings.region))
    try:
        return reader.read(settings.client_secret_parameter_name)
    except SecretUnavailableError as error:
        raise ConfigurationError(
            f"Cannot read the client secret from parameter "
            f"{settings.client_secret_parameter_name}: {error}"
        ) from None


def _cognito_provider(settings: Settings) -> IdentityProvider:
    client_secret = _read_client_secret(settings)
    client = create_cognito_client(settings.region)
    if not hasattr(client, "get_tokens_from_refresh_token"):
        # Renewal needs this operation. A Lambda runtime with an older boto3 would otherwise
        # fail only on /auth/refresh; failing at cold start makes the cause obvious.
        raise ConfigurationError(
            "The boto3 of this runtime has no get_tokens_from_refresh_token: "
            "package a newer boto3 with the function."
        )
    return CognitoIdentityProvider(client, settings.app_client_id, client_secret)


def build_container(
    environ: Mapping[str, str], identity_provider: IdentityProvider | None = None
) -> Container:
    """Validate the settings and read the client secret (raising ``ConfigurationError``).

    The secret is read from Parameter Store here, once per cold start, so a missing parameter
    makes the function fail to start instead of failing every request.
    """
    settings = load_settings(environ)
    configure_logging()
    return Container(settings, identity_provider or _cognito_provider(settings))
