"""Tests of scripts/post_destroy_check.py with a fake AWS CLI wrapper (no AWS access)."""

from __future__ import annotations

from typing import Any

import pytest

import post_destroy_check as check

REPO = "over-engineered-simple-calculator-webpage"
BASE = ["--repo-name", REPO, "--env", "dev"]
EAST2, EAST1 = "us-east-2", "us-east-1"


class FakeCli:
    """Answers aws(args, profile, region) from {(service, command, region): response}."""

    def __init__(self, answers: dict[tuple[str, str, str], Any] | None = None) -> None:
        self.answers = answers or {}
        self.calls: list[tuple[str, str, str]] = []

    def __call__(self, args: list[str], profile: str | None, region: str) -> dict[str, Any]:
        key = (args[0], args[1], region)
        self.calls.append(key)
        answer = self.answers.get(key, {})
        if isinstance(answer, Exception):
            raise answer
        return dict(answer)


def run(monkeypatch: pytest.MonkeyPatch, cli: FakeCli, *extra: str) -> int:
    monkeypatch.setattr(check, "aws", cli)
    return check.main([*BASE, *extra])


def secret(name: str, deleted: bool = False) -> dict[str, Any]:
    item: dict[str, Any] = {"Name": name, "Tags": [{"Key": "repo-name", "Value": REPO}]}
    if deleted:
        item["DeletedDate"] = 1.0
    return item


def test_clean_environment_passes_and_both_regions_are_read(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cli = FakeCli()
    assert run(monkeypatch, cli) == 0
    regions = {region for _, _, region in cli.calls}
    assert regions == {EAST2, EAST1}
    for service, command in (
        ("secretsmanager", "list-secrets"),
        ("sns", "list-topics"),
        ("cloudwatch", "describe-alarms"),
        ("logs", "describe-log-groups"),
    ):
        assert (service, command, EAST1) in cli.calls and (service, command, EAST2) in cli.calls


def test_region_option_limits_the_regions(monkeypatch: pytest.MonkeyPatch) -> None:
    cli = FakeCli()
    assert run(monkeypatch, cli, "--region", EAST2) == 0
    assert {region for _, _, region in cli.calls} == {EAST2}


def test_active_secret_is_left_over(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    cli = FakeCli(
        {("secretsmanager", "list-secrets", EAST2): {"SecretList": [secret("sm-useast2-oecalc-auth-app-client-dev")]}}
    )
    assert run(monkeypatch, cli) == 1
    assert "sm-useast2-oecalc-auth-app-client-dev" in capsys.readouterr().out


def test_pending_deletion_secret_is_expected_unless_strict(monkeypatch: pytest.MonkeyPatch) -> None:
    answers = {
        ("secretsmanager", "list-secrets", EAST2): {
            "SecretList": [secret("sm-useast2-oecalc-auth-app-client-dev", deleted=True)]
        }
    }
    assert run(monkeypatch, FakeCli(answers)) == 0
    assert run(monkeypatch, FakeCli(answers), "--strict-secrets") == 1


def test_secret_of_another_repository_is_ignored(monkeypatch: pytest.MonkeyPatch) -> None:
    other = {
        "Name": "sm-useast2-oecalc-other-dev",
        "Tags": [{"Key": "repo-name", "Value": "other"}],
    }
    cli = FakeCli({("secretsmanager", "list-secrets", EAST2): {"SecretList": [other]}})
    assert run(monkeypatch, cli) == 0


def test_sns_topic_in_us_east_1_is_left_over(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    arn = "arn:aws:sns:us-east-1:000000000000:sns-useast1-oecalc-web-alerts-dev"
    cli = FakeCli(
        {
            ("sns", "list-topics", EAST1): {"Topics": [{"TopicArn": arn}]},
            ("sns", "list-tags-for-resource", EAST1): {"Tags": [{"Key": "repo-name", "Value": REPO}]},
        }
    )
    assert run(monkeypatch, cli) == 1
    assert "sns topic" in capsys.readouterr().out


def test_topic_of_another_environment_or_repository_is_ignored(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    topics = [
        {"TopicArn": "arn:aws:sns:us-east-2:000000000000:sns-useast2-oecalc-auth-bff-alerts-prod"},
        {"TopicArn": "arn:aws:sns:us-east-2:000000000000:sns-useast2-oecalc-other-alerts-dev"},
    ]
    cli = FakeCli(
        {
            ("sns", "list-topics", EAST2): {"Topics": topics},
            ("sns", "list-tags-for-resource", EAST2): {"Tags": [{"Key": "repo-name", "Value": "other"}]},
        }
    )
    assert run(monkeypatch, cli) == 0


def test_alarm_is_left_over(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    alarm = {
        "AlarmName": "alrm-useast1-oecalc-web-cert-expiry-30d-dev",
        "AlarmArn": "arn:aws:cloudwatch:us-east-1:000000000000:alarm:alrm-useast1-oecalc-web-cert-expiry-30d-dev",
    }
    cli = FakeCli(
        {
            ("cloudwatch", "describe-alarms", EAST1): {"MetricAlarms": [alarm]},
            ("cloudwatch", "list-tags-for-resource", EAST1): {"Tags": [{"Key": "repo-name", "Value": REPO}]},
        }
    )
    assert run(monkeypatch, cli) == 1
    assert "alarm" in capsys.readouterr().out


def test_log_group_is_left_over(monkeypatch: pytest.MonkeyPatch) -> None:
    group = {
        "logGroupName": "/aws/lambda/fnc-useast2-oecalc-auth-bff-dev",
        "arn": "arn:aws:logs:us-east-2:000000000000:log-group:/aws/lambda/fnc-useast2-oecalc-auth-bff-dev:*",
    }
    cli = FakeCli({("logs", "describe-log-groups", EAST2): {"logGroups": [group]}})
    assert run(monkeypatch, cli) == 1


def test_tagged_resource_is_left_over(monkeypatch: pytest.MonkeyPatch) -> None:
    item = {"ResourceARN": "arn:aws:cloudfront::000000000000:distribution/EFAKE"}
    cli = FakeCli({("resourcegroupstaggingapi", "get-resources", EAST1): {"ResourceTagMappingList": [item]}})
    assert run(monkeypatch, cli) == 1


def test_read_failure_exits_2(monkeypatch: pytest.MonkeyPatch) -> None:
    cli = FakeCli({("resourcegroupstaggingapi", "get-resources", EAST2): RuntimeError("boom")})
    assert run(monkeypatch, cli) == 2


def test_missing_permission_on_an_optional_check_is_reported_as_skipped(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    cli = FakeCli({("sns", "list-topics", EAST2): RuntimeError("AccessDenied")})
    assert run(monkeypatch, cli) == 0
    out = capsys.readouterr().out
    assert "SKIPPED" in out and "sns" in out
