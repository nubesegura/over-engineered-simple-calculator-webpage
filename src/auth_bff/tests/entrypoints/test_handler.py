import base64
import hashlib
import hmac
import importlib
import json
import logging
import sys
from collections.abc import Iterator
from types import SimpleNamespace
from typing import Any

import pytest
from botocore.stub import Stubber

from auth_bff.adapters.outbound.cognito_identity_provider import CognitoIdentityProvider
from auth_bff.config.container import Container, build_container
from auth_bff.config.settings import ConfigurationError
from auth_bff.domain.errors import InvalidCredentialsError
from tests.fakes import REFRESH_TOKEN, TOKENS, FakeIdentityProvider, fake_credentials_client

ORIGIN = "https://calculator.example.com"
ENVIRONMENT = {
    "COGNITO_APP_CLIENT_ID": "client-id",
    "ALLOWED_ORIGIN": ORIGIN,
    "AWS_REGION": "us-east-2",
    "CLIENT_SECRET_PARAMETER_NAME": "/calc/dev/client-secret",
}
CLIENT_SECRET = "handler-client-secret-0123456789"
CONTEXT = SimpleNamespace(aws_request_id="req-123")
USERNAME = "someone@example.com"
PASSWORD = "very-secret-password"


def _import_handler() -> Any:
    sys.modules.pop("handler", None)
    return importlib.import_module("handler")


def _stub_ssm(monkeypatch: pytest.MonkeyPatch, stubber_out: list[Stubber]) -> None:
    client = fake_credentials_client("ssm")
    stubber = Stubber(client)
    stubber.add_response(
        "get_parameter",
        {"Parameter": {"Name": "n", "Type": "SecureString", "Value": CLIENT_SECRET}},
        {"Name": ENVIRONMENT["CLIENT_SECRET_PARAMETER_NAME"], "WithDecryption": True},
    )
    stubber.activate()
    stubber_out.append(stubber)
    monkeypatch.setattr("auth_bff.config.container.create_ssm_client", lambda region: client)


@pytest.fixture
def handler_module(monkeypatch: pytest.MonkeyPatch) -> Iterator[Any]:
    for name, value in ENVIRONMENT.items():
        monkeypatch.setenv(name, value)
    stubbers: list[Stubber] = []
    _stub_ssm(monkeypatch, stubbers)
    module = _import_handler()
    stubbers[0].assert_no_pending_responses()
    yield module
    sys.modules.pop("handler", None)


def _use(module: Any, provider: FakeIdentityProvider) -> None:
    module._container = build_container(ENVIRONMENT, provider)


def _event(path: str, body: str | None = None, cookies: list[str] | None = None) -> dict[str, Any]:
    event: dict[str, Any] = {
        "rawPath": path,
        "headers": {
            "origin": ORIGIN,
            "x-requested-with": "XMLHttpRequest",
            "content-type": "application/json",
        },
        "requestContext": {"http": {"method": "POST"}},
        "isBase64Encoded": False,
    }
    if body is not None:
        event["body"] = body
    if cookies is not None:
        event["cookies"] = cookies
    return event


def test_cold_start_fails_with_a_clear_error_when_variables_are_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for name in [*ENVIRONMENT, "ENVIRONMENT"]:
        monkeypatch.delenv(name, raising=False)

    with pytest.raises(ConfigurationError, match="COGNITO_APP_CLIENT_ID"):
        _import_handler()
    sys.modules.pop("handler", None)


def test_the_cognito_adapter_is_built_at_cold_start_with_the_secret_from_ssm(
    handler_module: Any,
) -> None:
    container: Container = handler_module._container

    assert isinstance(container.identity_provider, CognitoIdentityProvider)
    assert container.settings.app_client_id == "client-id"


def test_cold_start_fails_when_the_runtime_boto3_cannot_renew_tokens(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for name, value in ENVIRONMENT.items():
        monkeypatch.setenv(name, value)
    ssm = fake_credentials_client("ssm")
    stubber = Stubber(ssm)
    stubber.add_response("get_parameter", {"Parameter": {"Value": CLIENT_SECRET}})
    stubber.activate()
    monkeypatch.setattr("auth_bff.config.container.create_ssm_client", lambda region: ssm)
    monkeypatch.setattr(
        "auth_bff.config.container.create_cognito_client", lambda region: SimpleNamespace()
    )

    with pytest.raises(ConfigurationError, match="get_tokens_from_refresh_token"):
        _import_handler()
    sys.modules.pop("handler", None)


@pytest.mark.parametrize("code", ["ParameterNotFound", "AccessDeniedException"])
def test_cold_start_fails_when_the_secret_parameter_cannot_be_read(
    monkeypatch: pytest.MonkeyPatch, code: str
) -> None:
    for name, value in ENVIRONMENT.items():
        monkeypatch.setenv(name, value)
    client = fake_credentials_client("ssm")
    stubber = Stubber(client)
    stubber.add_client_error("get_parameter", service_error_code=code, service_message="DETAIL")
    stubber.activate()
    monkeypatch.setattr("auth_bff.config.container.create_ssm_client", lambda region: client)

    with pytest.raises(ConfigurationError) as caught:
        _import_handler()
    sys.modules.pop("handler", None)

    message = str(caught.value)
    assert ENVIRONMENT["CLIENT_SECRET_PARAMETER_NAME"] in message
    assert code in message
    assert "DETAIL" not in message
    assert caught.value.__cause__ is None


def test_login_refresh_and_logout_through_the_handler(handler_module: Any) -> None:
    provider = FakeIdentityProvider()
    _use(handler_module, provider)
    cookie = f"__Secure-oecalc-refresh={REFRESH_TOKEN}"

    login = handler_module.handler(
        _event("/auth/login", json.dumps({"username": USERNAME, "password": PASSWORD})), CONTEXT
    )
    refresh = handler_module.handler(_event("/auth/refresh", cookies=[cookie]), CONTEXT)
    logout = handler_module.handler(_event("/auth/logout", cookies=[cookie]), CONTEXT)

    assert login["statusCode"] == 200
    assert json.loads(login["body"])["id_token"] == TOKENS.id_token
    assert len(login["cookies"]) == 1 and "Max-Age=86400" in login["cookies"][0]
    assert refresh["statusCode"] == 200 and "cookies" not in refresh
    assert logout["statusCode"] == 204 and "Max-Age=0" in logout["cookies"][0]
    assert [call[0] for call in provider.calls] == ["sign_in", "renew", "revoke"]


def test_a_failed_login_log_has_hash_and_error_type_and_no_secret(
    handler_module: Any, caplog: pytest.LogCaptureFixture
) -> None:
    _use(handler_module, FakeIdentityProvider(InvalidCredentialsError("NotAuthorizedException")))
    caplog.set_level(logging.DEBUG)

    response = handler_module.handler(
        _event("/auth/login", json.dumps({"username": USERNAME, "password": PASSWORD})), CONTEXT
    )

    assert response["statusCode"] == 401
    lines = [record.getMessage() for record in caplog.records]
    assert len(lines) == 1
    entry = json.loads(lines[0])
    assert entry == {
        "endpoint": "login",
        "status": 401,
        "outcome": "invalid_credentials",
        "request_id": "req-123",
        "error_type": "NotAuthorizedException",
        "username_hash": hashlib.sha256(USERNAME.encode()).hexdigest()[:12],
    }
    text = caplog.text
    for secret in (PASSWORD, USERNAME, "someone", TOKENS.id_token, TOKENS.access_token):
        assert secret not in text


def test_a_successful_request_log_never_holds_tokens_or_the_cookie(
    handler_module: Any, caplog: pytest.LogCaptureFixture
) -> None:
    _use(handler_module, FakeIdentityProvider())
    caplog.set_level(logging.DEBUG)

    handler_module.handler(
        _event("/auth/refresh", cookies=[f"__Secure-oecalc-refresh={REFRESH_TOKEN}"]), CONTEXT
    )

    assert json.loads(caplog.records[0].getMessage()) == {
        "endpoint": "refresh",
        "status": 200,
        "outcome": "ok",
        "request_id": "req-123",
    }
    for secret in (REFRESH_TOKEN, TOKENS.id_token, TOKENS.access_token):
        assert secret not in caplog.text


def _secret_hash(username: str) -> str:
    digest = hmac.new(
        CLIENT_SECRET.encode(),
        (username + ENVIRONMENT["COGNITO_APP_CLIENT_ID"]).encode(),
        hashlib.sha256,
    ).digest()
    return base64.b64encode(digest).decode()


def test_no_log_line_or_error_holds_the_client_secret_or_the_hash(
    caplog: pytest.LogCaptureFixture,
) -> None:
    cognito = fake_credentials_client("cognito-idp")
    with Stubber(cognito) as stubber:
        stubber.add_response(
            "initiate_auth",
            {
                "AuthenticationResult": {
                    "IdToken": "id",
                    "AccessToken": "access",
                    "RefreshToken": REFRESH_TOKEN,
                    "ExpiresIn": 3600,
                }
            },
        )
        stubber.add_client_error("get_tokens_from_refresh_token", "NotAuthorizedException")
        stubber.add_client_error("revoke_token", "InternalErrorException")
        provider = CognitoIdentityProvider(cognito, "client-id", CLIENT_SECRET)
        container = build_container(ENVIRONMENT, provider)
        caplog.set_level(logging.DEBUG)
        cookie = f"__Secure-oecalc-refresh={REFRESH_TOKEN}"
        body = json.dumps({"username": USERNAME, "password": PASSWORD})

        responses = [
            container.function_url.handle(_event("/auth/login", body), "r1"),
            container.function_url.handle(_event("/auth/refresh", cookies=[cookie]), "r2"),
            container.function_url.handle(_event("/auth/logout", cookies=[cookie]), "r3"),
        ]

    assert [item["statusCode"] for item in responses] == [200, 401, 502]
    visible = caplog.text + json.dumps(responses)
    assert CLIENT_SECRET not in visible
    assert _secret_hash(USERNAME) not in visible
