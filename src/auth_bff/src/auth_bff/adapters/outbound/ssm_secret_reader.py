"""AWS Systems Manager Parameter Store implementation of the secret reader port.

Unlike the Cognito client, this one is a normal signed client: it uses the function role.
"""

from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

from auth_bff.application.ports import SecretUnavailableError

_CONNECT_TIMEOUT_SECONDS = 2
_READ_TIMEOUT_SECONDS = 5


def create_ssm_client(region: str) -> Any:
    """Build the ``ssm`` client with short timeouts and the default retries."""
    config = Config(
        connect_timeout=_CONNECT_TIMEOUT_SECONDS,
        read_timeout=_READ_TIMEOUT_SECONDS,
        retries={"mode": "standard"},
    )
    return boto3.client("ssm", region_name=region, config=config)


class SsmSecretReader:
    """Reads a ``SecureString`` parameter, decrypted."""

    def __init__(self, client: Any) -> None:
        self._client = client

    def read(self, name: str) -> str:
        try:
            response = self._client.get_parameter(Name=name, WithDecryption=True)
        except ClientError as error:
            code = str(error.response.get("Error", {}).get("Code", "ClientError"))
            raise SecretUnavailableError(code) from None
        except BotoCoreError as error:
            raise SecretUnavailableError(type(error).__name__) from None
        value = response.get("Parameter", {}).get("Value")
        if not isinstance(value, str) or not value:
            raise SecretUnavailableError("EmptyParameter")
        return value
