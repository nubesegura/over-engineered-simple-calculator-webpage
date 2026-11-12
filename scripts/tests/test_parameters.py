"""Consistency of parameters/dev.json, parameters/prod.json and templates/stacks.json."""

from __future__ import annotations

import json
import re
from typing import Any

import pytest

import cfn_deploy
from iac_common import REPO_ROOT, load_stacks

MANDATORY_TAGS = {"team-owner", "project-name", "app-name", "repo-name", "env-type"}
FORBIDDEN_KEYS = ("Email", "Secret", "Password", "Token", "HostedZoneId")


def load(env: str) -> dict[str, Any]:
    config = json.loads((REPO_ROOT / "parameters" / f"{env}.json").read_text(encoding="utf-8"))
    assert isinstance(config, dict)
    return config


def test_both_files_have_identical_keys() -> None:
    dev, prod = load("dev"), load("prod")
    assert set(dev) == set(prod) == {"Parameters", "Tags"}
    assert set(dev["Parameters"]) == set(prod["Parameters"])
    assert set(dev["Tags"]) == set(prod["Tags"]) == MANDATORY_TAGS


@pytest.mark.parametrize("env", ["dev", "prod"])
def test_environment_identity_is_consistent(env: str) -> None:
    config = load(env)
    assert config["Parameters"]["EnvType"] == env
    assert config["Tags"]["env-type"] == env
    assert config["Tags"]["repo-name"] == "over-engineered-simple-calculator-webpage"


@pytest.mark.parametrize("env", ["dev", "prod"])
def test_values_are_strings_without_secrets_or_account_data(env: str) -> None:
    config = load(env)
    assert all(isinstance(v, str) for v in config["Parameters"].values())
    assert all(isinstance(v, str) for v in config["Tags"].values())
    assert not [k for k in config["Parameters"] if any(word in k for word in FORBIDDEN_KEYS)]
    assert config["Parameters"]["WebAclArn"] == ""
    assert not re.search(r"\d{12}", json.dumps(config))


def test_prod_invariants_hold() -> None:
    prod = load("prod")["Parameters"]
    assert prod["UserPoolDeletionProtection"] == "ACTIVE"
    assert prod["TracingMode"] == "Active"
    assert prod["LogRetentionDays"] == "365"
    assert prod["PriceClass"] == "PriceClass_All"
    assert ".dev." not in prod["DomainName"]


def test_dev_uses_the_cheap_settings() -> None:
    dev = load("dev")["Parameters"]
    assert dev["UserPoolDeletionProtection"] == "INACTIVE"
    assert dev["TracingMode"] == "PassThrough"
    assert dev["PriceClass"] == "PriceClass_100"
    assert dev["DomainName"].split(".", 1)[1].startswith("dev.")


def test_stacks_match_between_environments() -> None:
    _, dev = load_stacks("dev")
    _, prod = load_stacks("prod")
    keys = ("unit", "region", "template", "sam")
    assert [[e[k] for k in keys] for e in dev] == [[e[k] for k in keys] for e in prod]
    assert all(e["stack"].endswith("-dev") for e in dev)
    assert all(e["stack"].endswith("-prod") for e in prod)
    assert [e["unit"] for e in dev] == ["auth", "cert", "auth-bff", "frontend"]


@pytest.mark.parametrize("env", ["dev", "prod"])
def test_every_template_parameter_has_a_source(env: str) -> None:
    config = load(env)
    _, entries = load_stacks(env)
    for entry in entries:
        template = (REPO_ROOT / entry["template"]).read_text(encoding="utf-8")
        consumed = {p for p, _, _ in cfn_deploy.CONSUMES.get(entry["unit"], [])}
        provided = (
            set(config["Parameters"]) | set(cfn_deploy.TAG_PARAMETERS) | set(cfn_deploy.ENV_PARAMETERS) | consumed
        )
        required = {n for n, default in cfn_deploy.template_parameters(template).items() if default is None}
        assert required <= provided, f"{entry['template']}: no source for {sorted(required - provided)}"


def test_consumed_outputs_exist_in_the_producer_templates() -> None:
    _, entries = load_stacks("dev")
    templates = {e["unit"]: (REPO_ROOT / e["template"]).read_text(encoding="utf-8") for e in entries}
    for consumer, links in cfn_deploy.CONSUMES.items():
        for _, producer, key in links:
            outputs = templates[producer].split("\nOutputs:", 1)[1]
            assert f"\n  {key}:" in outputs, f"{producer} has no output {key} (used by {consumer})"


def test_stack_policy_is_valid_json_with_the_protected_resources() -> None:
    policy = cfn_deploy.load_stack_policy()
    template_text = "".join((REPO_ROOT / e["template"]).read_text(encoding="utf-8") for e in load_stacks("prod")[1])
    for resource in policy["Statement"][1]["Resource"]:
        logical = resource.removeprefix("LogicalResourceId/")
        assert f"\n  {logical}:" in template_text
