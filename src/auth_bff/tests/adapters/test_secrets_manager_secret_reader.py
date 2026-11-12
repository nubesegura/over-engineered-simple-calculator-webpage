from collections.abc import Iterator

import pytest
from botocore.exceptions import EndpointConnectionError
from botocore.stub import Stubber

from auth_bff.adapters.outbound.secrets_manager_secret_reader import (
    SecretsManagerSecretReader,
    create_secrets_manager_client,
)
from auth_bff.application.ports import SecretUnavailableError
from tests.fakes import fake_credentials_client

SECRET_ID = "sm-useast2-oecalc-auth-app-client-dev"
SECRET = "sm-secret-value-0123456789abcdef"


@pytest.fixture
def stubbed() -> Iterator[tuple[SecretsManagerSecretReader, Stubber]]:
    client = fake_credentials_client("secretsmanager")
    with Stubber(client) as stubber:
        yield SecretsManagerSecretReader(client), stubber
        stubber.assert_no_pending_responses()


def test_the_client_uses_short_timeouts_and_the_given_region(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")

    client = create_secrets_manager_client("us-east-2")

    assert client.meta.region_name == "us-east-2"
    assert client.meta.config.connect_timeout == 2
    assert client.meta.config.read_timeout == 5


def test_the_secret_string_is_returned(
    stubbed: tuple[SecretsManagerSecretReader, Stubber],
) -> None:
    reader, stubber = stubbed
    stubber.add_response(
        "get_secret_value",
        {"Name": SECRET_ID, "SecretString": SECRET},
        {"SecretId": SECRET_ID},
    )

    assert reader.read(SECRET_ID) == SECRET


@pytest.mark.parametrize(
    "code", ["ResourceNotFoundException", "AccessDeniedException", "InternalServiceError"]
)
def test_a_secrets_manager_error_is_reported_with_its_code_only(
    stubbed: tuple[SecretsManagerSecretReader, Stubber], code: str
) -> None:
    reader, stubber = stubbed
    stubber.add_client_error("get_secret_value", service_error_code=code, service_message="DETAIL")

    with pytest.raises(SecretUnavailableError) as caught:
        reader.read(SECRET_ID)

    assert str(caught.value) == code
    assert caught.value.__cause__ is None


def test_a_network_error_is_reported_by_its_class_name() -> None:
    class Broken:
        def get_secret_value(self, **_: object) -> dict[str, object]:
            raise EndpointConnectionError(endpoint_url="https://secretsmanager.example")

    with pytest.raises(SecretUnavailableError, match="EndpointConnectionError"):
        SecretsManagerSecretReader(Broken()).read(SECRET_ID)


@pytest.mark.parametrize(
    "response",
    [
        {"Name": SECRET_ID},
        {"Name": SECRET_ID, "SecretBinary": b"binary"},
    ],
)
def test_a_missing_or_empty_secret_string_is_unavailable(
    stubbed: tuple[SecretsManagerSecretReader, Stubber], response: dict[str, object]
) -> None:
    reader, stubber = stubbed
    stubber.add_response("get_secret_value", response)

    with pytest.raises(SecretUnavailableError, match="EmptySecret"):
        reader.read(SECRET_ID)


def test_an_empty_secret_string_is_unavailable() -> None:
    class EmptyValue:
        def get_secret_value(self, **_: object) -> dict[str, object]:
            return {"SecretString": ""}

    with pytest.raises(SecretUnavailableError, match="EmptySecret"):
        SecretsManagerSecretReader(EmptyValue()).read(SECRET_ID)
