"""Settings read from environment variables and validated at cold start."""

from collections.abc import Mapping
from dataclasses import dataclass
from urllib.parse import urlsplit

LOCAL_ENVIRONMENT = "local"
_LOCAL_DEFAULTS = {
    "COGNITO_APP_CLIENT_ID": "local-app-client-id",
    "ALLOWED_ORIGIN": "http://localhost:8080",
    "AWS_REGION": "us-east-2",
    "CLIENT_SECRET_PARAMETER_NAME": "/local/client-secret",
}
_REQUIRED = (
    "COGNITO_APP_CLIENT_ID",
    "ALLOWED_ORIGIN",
    "AWS_REGION",
    "CLIENT_SECRET_PARAMETER_NAME",
)
_LOCAL_HOST = "localhost"


class ConfigurationError(Exception):
    """A required setting is missing or invalid; the function must fail at cold start."""


@dataclass(frozen=True)
class Settings:
    app_client_id: str
    allowed_origin: str
    region: str
    environment: str
    client_secret_parameter_name: str


def load_settings(environ: Mapping[str, str]) -> Settings:
    """Read the settings. Only ``ENVIRONMENT=local`` may fall back to defaults."""
    environment = environ.get("ENVIRONMENT", "")
    defaults = _LOCAL_DEFAULTS if environment == LOCAL_ENVIRONMENT else {}
    values = {name: environ.get(name) or defaults.get(name, "") for name in _REQUIRED}
    missing = [name for name, value in values.items() if not value]
    if missing:
        raise ConfigurationError(f"Missing required environment variables: {', '.join(missing)}")
    allowed_origin = values["ALLOWED_ORIGIN"]
    if not _is_valid_origin(allowed_origin, environment == LOCAL_ENVIRONMENT):
        raise ConfigurationError(
            "ALLOWED_ORIGIN must be https://<host> without a path "
            "(http://localhost is only allowed when ENVIRONMENT=local)"
        )
    return Settings(
        app_client_id=values["COGNITO_APP_CLIENT_ID"],
        allowed_origin=allowed_origin,
        region=values["AWS_REGION"],
        environment=environment,
        client_secret_parameter_name=values["CLIENT_SECRET_PARAMETER_NAME"],
    )


def _is_valid_origin(origin: str, local: bool) -> bool:
    try:
        parts = urlsplit(origin)
        port = parts.port
    except ValueError:
        return False
    if parts.path or parts.query or parts.fragment or parts.username is not None:
        return False
    if origin.endswith(("?", "#")) or not parts.hostname:
        return False
    if parts.scheme == "https":
        return port is None
    return local and parts.scheme == "http" and parts.hostname == _LOCAL_HOST
