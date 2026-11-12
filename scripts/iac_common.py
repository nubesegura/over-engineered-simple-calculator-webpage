"""Helpers shared by the scripts of the CloudFormation path: stack list, AWS clients, error codes."""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

REPO_ROOT = Path(__file__).resolve().parents[1]
STACKS_FILE = REPO_ROOT / "templates" / "stacks.json"
ENVIRONMENTS = ("dev", "prod")

# (service name, region) -> boto3 client. Tests pass a factory that returns fakes.
ClientFactory = Callable[[str, str], Any]


class ConfigError(Exception):
    """A repository file (stacks.json, parameters) is missing or malformed."""


def make_client_factory(profile: str | None = None) -> ClientFactory:
    """Real boto3 clients with bounded timeouts and standard retries."""
    session = boto3.Session(profile_name=profile)
    config = Config(retries={"mode": "standard", "max_attempts": 5}, connect_timeout=5, read_timeout=60)

    def factory(service: str, region: str) -> Any:
        return session.client(service, region_name=region, config=config)

    return factory


def error_code(exc: ClientError) -> str:
    """The AWS error code of a ClientError, or an empty string."""
    return str(exc.response.get("Error", {}).get("Code", ""))


def error_message(exc: ClientError) -> str:
    return str(exc.response.get("Error", {}).get("Message", ""))


def is_missing_stack(exc: ClientError) -> bool:
    """describe_stacks answers ValidationError 'does not exist' for an unknown stack name."""
    return error_code(exc) == "ValidationError" and "does not exist" in error_message(exc)


def load_stacks(env: str, stacks_file: Path = STACKS_FILE) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """The whole stacks.json and the ordered stack entries of one environment."""
    try:
        data = json.loads(stacks_file.read_text(encoding="utf-8"))
        entries = data["environments"][env]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ConfigError(f"cannot read {stacks_file.name} for {env}: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(entries, list):
        raise ConfigError(f"{stacks_file.name} is malformed")
    return data, entries
