from collections.abc import Iterator

import pytest
from botocore.exceptions import EndpointConnectionError
from botocore.stub import Stubber

from auth_bff.adapters.outbound.ssm_secret_reader import SsmSecretReader, create_ssm_client
from auth_bff.application.ports import SecretUnavailableError
from tests.fakes import fake_credentials_client

NAME = "/calc/dev/client-secret"
SECRET = "ssm-secret-value-0123456789abcdef"


@pytest.fixture
def stubbed() -> Iterator[tuple[SsmSecretReader, Stubber]]:
    client = fake_credentials_client("ssm")
    with Stubber(client) as stubber:
        yield SsmSecretReader(client), stubber
        stubber.assert_no_pending_responses()


def test_the_client_uses_short_timeouts_and_the_given_region(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")

    client = create_ssm_client("us-east-2")

    assert client.meta.region_name == "us-east-2"
    assert client.meta.config.connect_timeout == 2
    assert client.meta.config.read_timeout == 5


def test_the_parameter_is_read_with_decryption(
    stubbed: tuple[SsmSecretReader, Stubber],
) -> None:
    reader, stubber = stubbed
    stubber.add_response(
        "get_parameter",
        {"Parameter": {"Name": NAME, "Type": "SecureString", "Value": SECRET}},
        {"Name": NAME, "WithDecryption": True},
    )

    assert reader.read(NAME) == SECRET


@pytest.mark.parametrize(
    "code", ["ParameterNotFound", "AccessDeniedException", "InternalServerError"]
)
def test_an_ssm_error_is_reported_with_its_code_only(
    stubbed: tuple[SsmSecretReader, Stubber], code: str
) -> None:
    reader, stubber = stubbed
    stubber.add_client_error("get_parameter", service_error_code=code, service_message="DETAIL")

    with pytest.raises(SecretUnavailableError) as caught:
        reader.read(NAME)

    assert str(caught.value) == code
    assert caught.value.__cause__ is None


def test_a_network_error_is_reported_by_its_class_name() -> None:
    class Broken:
        def get_parameter(self, **_: object) -> dict[str, object]:
            raise EndpointConnectionError(endpoint_url="https://ssm.example")

    with pytest.raises(SecretUnavailableError, match="EndpointConnectionError"):
        SsmSecretReader(Broken()).read(NAME)


@pytest.mark.parametrize("response", [{"Parameter": {}}, {"Parameter": {"Value": ""}}, {}])
def test_a_missing_or_empty_value_is_unavailable(
    stubbed: tuple[SsmSecretReader, Stubber], response: dict[str, object]
) -> None:
    reader, stubber = stubbed
    stubber.add_response("get_parameter", response)

    with pytest.raises(SecretUnavailableError, match="EmptyParameter"):
        reader.read(NAME)
