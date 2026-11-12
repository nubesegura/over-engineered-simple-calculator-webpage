"""Tests of scripts/iac_inventory.py with fake boto3 clients (no AWS access)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fakes import FakeCfn, FakeFactory, client_error, resource

import iac_inventory

SECRET_VALUE = "super-secret-output-value"


def make_factory() -> tuple[FakeFactory, FakeCfn, FakeCfn]:
    log: list[tuple[str, ...]] = []
    east2, east1 = FakeCfn("us-east-2", log), FakeCfn("us-east-1", log)
    east2.add_stack(
        "stk-useast2-oecalc-auth-dev",
        "CREATE_COMPLETE",
        outputs={"UserPoolId": SECRET_VALUE, "AppClientId": SECRET_VALUE},
        resources=[
            resource("UserPool", "AWS::Cognito::UserPool", "pool-physical-id"),
            resource("AppClient", "AWS::Cognito::UserPoolClient", "client-physical-id"),
        ],
    )
    east1.add_stack(
        "stk-useast1-oecalc-cert-dev",
        "UPDATE_COMPLETE",
        protection=True,
        resources=[resource("Certificate", "AWS::CertificateManager::Certificate", "arn-physical")],
    )
    east1.policies["stk-useast1-oecalc-cert-dev"] = "{}"
    factory = FakeFactory({("cloudformation", "us-east-2"): east2, ("cloudformation", "us-east-1"): east1})
    return factory, east2, east1


def test_inventory_lists_resources_per_stack_in_deploy_order() -> None:
    factory, _, _ = make_factory()
    inventory = iac_inventory.build_inventory("dev", factory)
    assert [s["unit"] for s in inventory["stacks"]] == ["auth", "cert", "auth-bff", "frontend"]
    auth, cert, bff, _frontend = inventory["stacks"]
    assert [r["logicalId"] for r in auth["resources"]] == ["AppClient", "UserPool"]
    assert auth["status"] == "CREATE_COMPLETE" and auth["outputKeys"] == [
        "AppClientId",
        "UserPoolId",
    ]
    assert cert["terminationProtection"] is True and cert["stackPolicy"] is True
    assert bff["status"] == "ABSENT" and bff["resources"] == []


def test_inventory_holds_no_values() -> None:
    factory, _, _ = make_factory()
    text = json.dumps(iac_inventory.build_inventory("dev", factory)) + iac_inventory.render_markdown(
        iac_inventory.build_inventory("dev", factory)
    )
    assert SECRET_VALUE not in text
    assert "physical" not in text


def test_markdown_has_one_section_per_stack() -> None:
    factory, _, _ = make_factory()
    markdown = iac_inventory.render_markdown(iac_inventory.build_inventory("dev", factory))
    assert markdown.count("### ") == 4
    assert "AWS::Cognito::UserPool" in markdown and "ABSENT" in markdown


def test_unreadable_stack_fails_closed() -> None:
    factory, east2, _ = make_factory()
    east2.describe_stacks = lambda StackName: (_ for _ in ()).throw(client_error("AccessDenied"))  # type: ignore[method-assign]
    assert iac_inventory.main(["--env", "dev"], client_factory=factory) == 1


def test_main_prints_json_and_writes_a_file(capsys: pytest.CaptureFixture[str], tmp_path: Path) -> None:
    factory, _, _ = make_factory()
    assert iac_inventory.main(["--env", "dev"], client_factory=factory) == 0
    assert json.loads(capsys.readouterr().out)["environment"] == "dev"
    target = tmp_path / "inventory.md"
    code = iac_inventory.main(["--env", "dev", "--format", "markdown", "--output", str(target)], client_factory=factory)
    assert code == 0 and target.read_text(encoding="utf-8").startswith("## ")
