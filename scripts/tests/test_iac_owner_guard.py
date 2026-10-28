"""Tests of scripts/iac_owner_guard.py with fake boto3 clients (no AWS access, no files written)."""

from __future__ import annotations

import io
import json
import tempfile
from typing import Any

import pytest
from botocore.exceptions import ProfileNotFound
from fakes import FakeFactory, client_error

import iac_owner_guard as guard

ACCOUNT = "111122223333"
STATE_WITH_RESOURCES = json.dumps(
    {
        "version": 4,
        "resources": [
            {"mode": "data", "type": "aws_region", "instances": [{}]},
            {
                "mode": "managed",
                "type": "aws_x",
                "instances": [{"attributes": {"s": "SECRET-VALUE"}}],
            },
        ],
    }
)
STATE_EMPTY = json.dumps({"version": 4, "resources": []})
AUTH_STACK = "stk-useast2-oecalc-auth-dev"
CERT_STACK = "stk-useast1-oecalc-cert-dev"


class FakeCfn:
    def __init__(self, stacks: dict[str, str], error: str | None = None, malformed: bool = False) -> None:
        self.stacks = stacks
        self.error = error
        self.malformed = malformed

    def describe_stacks(self, StackName: str) -> dict[str, Any]:
        if self.error:
            raise client_error(self.error)
        if self.malformed:
            return {"Stacks": [{"Name": StackName}]}
        if StackName not in self.stacks:
            raise client_error("ValidationError", f"Stack with id {StackName} does not exist")
        return {"Stacks": [{"StackName": StackName, "StackStatus": self.stacks[StackName]}]}


class FakeSts:
    def __init__(self, error: str | None = None) -> None:
        self.error = error

    def get_caller_identity(self) -> dict[str, str]:
        if self.error:
            raise client_error(self.error)
        return {"Account": ACCOUNT}


class FakeS3:
    def __init__(self, states: dict[str, str] | None = None, error: str | None = None) -> None:
        self.states = states or {}
        self.error = error

    def get_object(self, Bucket: str, Key: str) -> dict[str, Any]:
        if self.error:
            raise client_error(self.error)
        for unit, body in self.states.items():
            if f"/{unit}/" in Key:
                return {"Body": io.BytesIO(body.encode())}
        raise client_error("NoSuchKey")


def factory(
    stacks: dict[str, str] | None = None,
    states: dict[str, str] | None = None,
    cfn_error: str | None = None,
    s3_error: str | None = None,
    sts_error: str | None = None,
    malformed: bool = False,
) -> FakeFactory:
    return FakeFactory(
        {
            ("cloudformation", "*"): FakeCfn(stacks or {}, cfn_error, malformed),
            ("sts", "*"): FakeSts(sts_error),
            ("s3", "*"): FakeS3(states, s3_error),
        }
    )


def run(argv: list[str], fake: FakeFactory, environ: dict[str, str] | None = None) -> int:
    return guard.main(argv, client_factory=fake, environ=environ or {})


@pytest.mark.parametrize(
    ("tool", "owner", "expected"),
    [
        ("terraform", "none", 0),
        ("cloudformation", "none", 0),
        ("terraform", "terraform", 0),
        ("cloudformation", "cloudformation", 0),
        ("terraform", "cloudformation", 2),
        ("cloudformation", "terraform", 2),
    ],
)
def test_tool_and_ownership_matrix(tool: str, owner: str, expected: int) -> None:
    stacks = {AUTH_STACK: "CREATE_COMPLETE"} if owner == "cloudformation" else {}
    states = {"edge/auth": STATE_WITH_RESOURCES} if owner == "terraform" else {}
    assert run(["check", "--env", "dev", "--tool", tool], factory(stacks, states)) == expected


def test_both_owners_is_inconsistent() -> None:
    fake = factory({AUTH_STACK: "CREATE_COMPLETE"}, {"edge/auth": STATE_WITH_RESOURCES})
    assert run(["check", "--env", "dev", "--tool", "cloudformation"], fake) == 3
    assert run(["detect", "--env", "dev"], fake) == 3


@pytest.mark.parametrize("value", [None, "", "  "])
def test_unset_tool_resolves_to_cloudformation(value: str | None) -> None:
    environ = {} if value is None else {"IAC_TOOL": value}
    terraform_owned = factory(states={"edge/auth-bff": STATE_WITH_RESOURCES})
    assert run(["check", "--env", "dev"], terraform_owned, environ) == 2
    assert run(["check", "--env", "dev"], factory(), environ) == 0


def test_tool_from_environment_variable() -> None:
    fake = factory({AUTH_STACK: "CREATE_COMPLETE"})
    assert run(["check", "--env", "dev"], fake, {"IAC_TOOL": "terraform"}) == 2


def test_bogus_tool_exits_with_clear_message(capsys: pytest.CaptureFixture[str]) -> None:
    assert run(["check", "--env", "dev", "--tool", "bogus"], factory()) == 4
    assert "IAC_TOOL" in capsys.readouterr().out


def test_argument_errors_exit_4() -> None:
    assert run(["check", "--env", "staging"], factory()) == 4
    assert run([], factory()) == 4


def test_stacks_are_read_in_both_regions() -> None:
    fake = factory()
    run(["check", "--env", "prod", "--tool", "cloudformation"], fake)
    regions = {region for service, region in fake.requested if service == "cloudformation"}
    assert regions == {"us-east-1", "us-east-2"}


@pytest.mark.parametrize("status", ["ROLLBACK_COMPLETE", "REVIEW_IN_PROGRESS", "DELETE_FAILED", "UPDATE_COMPLETE"])
def test_any_status_but_delete_complete_counts_as_present(status: str) -> None:
    fake = factory({CERT_STACK: status})
    assert run(["check", "--env", "dev", "--tool", "terraform"], fake) == 2


def test_delete_complete_counts_as_none() -> None:
    fake = factory({CERT_STACK: "DELETE_COMPLETE"})
    assert run(["check", "--env", "dev", "--tool", "terraform"], fake) == 0


def test_empty_state_counts_as_none() -> None:
    fake = factory(states={"edge/auth": STATE_EMPTY})
    assert run(["check", "--env", "dev", "--tool", "cloudformation"], fake) == 0


@pytest.mark.parametrize("code", ["NoSuchBucket", "NoSuchKey"])
def test_missing_state_object_or_bucket_counts_as_none(code: str) -> None:
    assert run(["detect", "--env", "dev"], factory(s3_error=code)) == 0


@pytest.mark.parametrize(
    "fake",
    [
        factory(cfn_error="AccessDenied"),
        factory(cfn_error="Throttling"),
        factory(malformed=True),
        factory(s3_error="AccessDenied"),
        factory(s3_error="SlowDown"),
        factory(sts_error="AccessDenied"),
        factory(states={"edge/auth": "not json"}),
        factory(states={"edge/auth": json.dumps({"version": 4})}),
        factory(states={"edge/auth": json.dumps({"resources": "x"})}),
    ],
)
def test_unreadable_answers_fail_closed(fake: FakeFactory) -> None:
    assert run(["check", "--env", "dev", "--tool", "cloudformation"], fake) == 4
    assert run(["detect", "--env", "dev"], fake) == 4


def test_oversized_state_fails_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(guard, "MAX_STATE_BYTES", 10)
    fake = factory(states={"edge/auth": STATE_WITH_RESOURCES})
    assert run(["check", "--env", "dev", "--tool", "terraform"], fake) == 4


@pytest.mark.parametrize(
    ("stacks", "states", "owner"),
    [
        ({}, {}, "none"),
        ({AUTH_STACK: "CREATE_COMPLETE"}, {}, "cloudformation"),
        ({}, {"edge/frontend": STATE_WITH_RESOURCES}, "terraform"),
    ],
)
def test_detect_prints_owner(
    stacks: dict[str, str],
    states: dict[str, str],
    owner: str,
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert run(["detect", "--env", "dev"], factory(stacks, states)) == 0
    assert f"owner={owner}" in capsys.readouterr().out.splitlines()


def test_nothing_sensitive_is_printed(capsys: pytest.CaptureFixture[str]) -> None:
    fake = factory(states={"edge/auth": STATE_WITH_RESOURCES})
    run(["check", "--env", "dev", "--tool", "cloudformation"], fake)
    captured = capsys.readouterr()
    assert "SECRET-VALUE" not in captured.out + captured.err
    assert ACCOUNT not in captured.out + captured.err


def test_no_temporary_file_is_created(monkeypatch: pytest.MonkeyPatch) -> None:
    def forbidden(*args: object, **kwargs: object) -> None:
        raise AssertionError("the guard must not create temporary files")

    for name in ("TemporaryDirectory", "NamedTemporaryFile", "mkstemp", "mkdtemp", "TemporaryFile"):
        monkeypatch.setattr(tempfile, name, forbidden)
    fake = factory(states={"edge/auth": STATE_WITH_RESOURCES})
    assert run(["check", "--env", "dev", "--tool", "terraform"], fake) == 0


@pytest.mark.parametrize("command", ["check", "detect"])
def test_unknown_profile_exits_4(
    command: str, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def no_profile(profile: str | None) -> Any:
        raise ProfileNotFound(profile=profile)

    monkeypatch.setattr(guard, "make_client_factory", no_profile)
    assert guard.main([command, "--env", "dev", "--profile", "nope"], environ={"IAC_TOOL": "terraform"}) == 4
    assert "::error::" in capsys.readouterr().out
