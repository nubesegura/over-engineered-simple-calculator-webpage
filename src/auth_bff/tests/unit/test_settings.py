import pytest

from auth_bff.config.settings import ConfigurationError, Settings, load_settings

DEPLOYED = {
    "COGNITO_APP_CLIENT_ID": "client-id",
    "ALLOWED_ORIGIN": "https://calculator.example.com",
    "AWS_REGION": "us-east-2",
    "CLIENT_SECRET_PARAMETER_NAME": "/calc/dev/client-secret",
}


def test_deployed_settings_are_read_from_the_environment() -> None:
    assert load_settings(DEPLOYED) == Settings(
        app_client_id="client-id",
        allowed_origin="https://calculator.example.com",
        region="us-east-2",
        environment="",
        client_secret_parameter_name="/calc/dev/client-secret",
    )


@pytest.mark.parametrize("name", sorted(DEPLOYED))
def test_a_missing_variable_fails_with_its_name(name: str) -> None:
    environ = {key: value for key, value in DEPLOYED.items() if key != name}

    with pytest.raises(ConfigurationError, match=name):
        load_settings(environ)


def test_an_empty_variable_counts_as_missing() -> None:
    with pytest.raises(ConfigurationError, match="COGNITO_APP_CLIENT_ID"):
        load_settings({**DEPLOYED, "COGNITO_APP_CLIENT_ID": ""})


def test_no_defaults_apply_when_the_environment_is_not_local() -> None:
    with pytest.raises(ConfigurationError):
        load_settings({"ENVIRONMENT": "dev"})


def test_local_environment_falls_back_to_defaults() -> None:
    settings = load_settings({"ENVIRONMENT": "local"})

    assert settings.environment == "local"
    assert settings.app_client_id
    assert settings.allowed_origin == "http://localhost:8080"
    assert settings.region == "us-east-2"
    assert settings.client_secret_parameter_name


def test_local_environment_still_honors_given_values() -> None:
    settings = load_settings({"ENVIRONMENT": "local", **DEPLOYED})

    assert settings.app_client_id == "client-id"


@pytest.mark.parametrize(
    "origin",
    [
        "calculator.example.com",
        "https://calculator.example.com/",
        "https://calculator.example.com/app",
        "https://calculator.example.com?x=1",
        "https://calculator.example.com#top",
        "https://user@calculator.example.com",
        "https://calculator.example.com:8443",
        "https://calculator.example.com:port",
        "https://",
        "ftp://calculator.example.com",
        "http://calculator.example.com",
        "http://localhost",
        "http://localhost:8080",
    ],
)
def test_the_allowed_origin_must_be_an_https_origin_without_a_path(origin: str) -> None:
    with pytest.raises(ConfigurationError, match="ALLOWED_ORIGIN"):
        load_settings({**DEPLOYED, "ALLOWED_ORIGIN": origin})


@pytest.mark.parametrize("origin", ["http://localhost", "http://localhost:8080"])
def test_localhost_is_an_allowed_origin_only_in_local_mode(origin: str) -> None:
    settings = load_settings({**DEPLOYED, "ENVIRONMENT": "local", "ALLOWED_ORIGIN": origin})

    assert settings.allowed_origin == origin


@pytest.mark.parametrize(
    "origin", ["http://calculator.example.com", "http://localhost/app", "http://127.0.0.1:8080"]
)
def test_local_mode_does_not_allow_other_http_origins(origin: str) -> None:
    with pytest.raises(ConfigurationError, match="ALLOWED_ORIGIN"):
        load_settings({**DEPLOYED, "ENVIRONMENT": "local", "ALLOWED_ORIGIN": origin})
