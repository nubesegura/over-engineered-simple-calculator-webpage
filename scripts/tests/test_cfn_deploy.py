"""Tests of scripts/cfn_deploy.py with fake boto3 clients and a fake SAM runner (no AWS access)."""

from __future__ import annotations

import base64
import hashlib
import json
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from botocore.exceptions import ClientError, ProfileNotFound
from fakes import Clock, FakeBody, FakeCfn, FakeFactory, client_error, resource

import cfn_deploy

EMAIL = "alerts@example.test"
ZONE = "Z0FAKEZONE"
WAF = "arn:aws:wafv2:us-east-1:000000000000:global/webacl/fake/id"
BUCKET = "artifacts-bucket-fake"
ZIP_BYTES = b"zip-content"
ZIP_SHA = base64.b64encode(hashlib.sha256(ZIP_BYTES).digest()).decode()
PACKAGED = f"Resources:\n  F:\n    Properties:\n      CodeUri: s3://{BUCKET}/prefix/abc\n"
POOL = "us-east-2_FAKEPOOL"
CLIENT = "fakeclientid"
PUBLIC_CLIENT = "fakepublicclientid"
CERT_ARN = "arn:aws:acm:us-east-1:000000000000:certificate/fake"


def add_change(action: str, replacement: str | None = None, kind: str = "AWS::X::Y") -> dict[str, Any]:
    detail: dict[str, Any] = {"Action": action, "LogicalResourceId": "Res", "ResourceType": kind}
    if replacement is not None:
        detail["Replacement"] = replacement
    return {"Type": "Resource", "ResourceChange": detail}


class FakeSsm:
    def __init__(self, value: str | None = BUCKET) -> None:
        self.value = value

    def get_parameter(self, Name: str) -> dict[str, Any]:
        if self.value is None:
            raise client_error("ParameterNotFound")
        return {"Parameter": {"Value": self.value}}


class FakeS3:
    def __init__(self) -> None:
        self.bucket_exists = True
        self.versions: list[dict[str, str]] = []
        self.delete_errors: list[dict[str, str]] = []
        self.deleted: list[list[dict[str, str]]] = []

    def head_bucket(self, Bucket: str) -> dict[str, Any]:
        if not self.bucket_exists:
            raise client_error("404")
        return {}

    def get_object(self, Bucket: str, Key: str) -> dict[str, Any]:
        return {"Body": FakeBody(ZIP_BYTES)}

    def list_object_versions(self, Bucket: str, **kwargs: Any) -> dict[str, Any]:
        return {"Versions": list(self.versions), "DeleteMarkers": []}

    def delete_objects(self, Bucket: str, Delete: dict[str, Any]) -> dict[str, Any]:
        self.deleted.append(Delete["Objects"])
        self.versions = []
        return {"Errors": self.delete_errors}


class FakeAcm:
    def __init__(self, status: str = "ISSUED", domain: str | None = None) -> None:
        self.status = status
        self.domain = domain

    def describe_certificate(self, CertificateArn: str) -> dict[str, Any]:
        return {
            "Certificate": {
                "Status": self.status,
                "DomainName": self.domain or "over-engineered-simple-calculator.dev.nube-segura.com",
            }
        }


class FakeLambda:
    def __init__(self, sha: str = ZIP_SHA) -> None:
        self.sha = sha

    def get_function_configuration(self, FunctionName: str) -> dict[str, str]:
        return {"CodeSha256": self.sha}


class FakeRoute53:
    def __init__(self, name: str = "dev.nube-segura.com.") -> None:
        self.name = name

    def get_hosted_zone(self, Id: str) -> dict[str, Any]:
        return {"HostedZone": {"Name": self.name}}


class FakeSecrets:
    def __init__(self, secret: dict[str, Any] | None) -> None:
        self.secret = secret
        self.forced: list[str] = []

    def describe_secret(self, SecretId: str) -> dict[str, Any]:
        if self.secret is None:
            raise client_error("ResourceNotFoundException")
        return self.secret

    def delete_secret(self, SecretId: str, ForceDeleteWithoutRecovery: bool) -> dict[str, Any]:
        assert ForceDeleteWithoutRecovery is True
        self.forced.append(SecretId)
        return {}


class FakeCognito:
    def describe_user_pool(self, UserPoolId: str) -> dict[str, Any]:
        return {"UserPool": {"EstimatedNumberOfUsers": 7}}


class World:
    """The fake account: one CloudFormation per Region plus the other services."""

    def __init__(self, env: str = "dev") -> None:
        self.env = env
        self.log: list[tuple[str, ...]] = []
        self.east2 = FakeCfn("us-east-2", self.log)
        self.east1 = FakeCfn("us-east-1", self.log)
        self.s3 = FakeS3()
        self.acm = FakeAcm(domain=None if env == "dev" else "over-engineered-simple-calculator.nube-segura.com")
        self.lambda_ = FakeLambda()
        self.route53 = FakeRoute53("dev.nube-segura.com." if env == "dev" else "nube-segura.com.")
        self.secrets = FakeSecrets(None)
        self.ssm = FakeSsm()
        self.commands: list[list[str]] = []
        self.sam_failure = False
        self.clock = Clock()
        suffix = env
        self.east2.outputs_on_create = {
            f"stk-useast2-oecalc-auth-{suffix}": {
                "UserPoolId": POOL,
                "AppClientId": CLIENT,
                "PublicAppClientId": PUBLIC_CLIENT,
                "AppClientSecretName": f"sm-useast2-oecalc-auth-app-client-{suffix}",
                "AppClientSecretArn": "arn:aws:secretsmanager:us-east-2:000000000000:secret:fake",
            },
            f"stk-useast2-oecalc-auth-bff-{suffix}": {
                "FunctionName": f"fnc-useast2-oecalc-auth-bff-{suffix}",
                "FunctionUrlHost": "abc.lambda-url.us-east-2.on.aws",
            },
            f"stk-useast2-oecalc-frontend-{suffix}": {
                "BucketName": "web-bucket",
                "DistributionId": "EFAKE",
                "WebsiteUrl": "https://example.test",
            },
        }
        self.east1.outputs_on_create = {f"stk-useast1-oecalc-cert-{suffix}": {"CertificateArn": CERT_ARN}}

    def factory(self) -> FakeFactory:
        return FakeFactory(
            {
                ("cloudformation", "us-east-2"): self.east2,
                ("cloudformation", "us-east-1"): self.east1,
                ("s3", "*"): self.s3,
                ("acm", "us-east-1"): self.acm,
                ("lambda", "*"): self.lambda_,
                ("route53", "*"): self.route53,
                ("secretsmanager", "*"): self.secrets,
                ("ssm", "*"): self.ssm,
                ("cognito-idp", "*"): FakeCognito(),
            }
        )

    def runner(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        self.commands.append(command)
        code = 1 if self.sam_failure and command[1] == "package" else 0
        return subprocess.CompletedProcess(command, code, "", "sam failed" if code else "")

    def files(self, path: Path) -> str:
        if path.name == "packaged.yaml":
            return PACKAGED
        return path.read_text(encoding="utf-8")

    def environ(self) -> dict[str, str]:
        values = {
            "ROUTE53_ZONE_ID": ZONE,
            "SUPPORT_EMAIL": EMAIL,
            "GITHUB_RUN_ID": "7",
            "GITHUB_RUN_ATTEMPT": "1",
        }
        if self.env == "prod":
            values["WAF_WEB_ACL_ARN"] = WAF
        return values

    def deployer(self, environ: dict[str, str] | None = None) -> cfn_deploy.Deployer:
        return cfn_deploy.Deployer(
            env=self.env,
            factory=self.factory(),
            runner=self.runner,
            environ=self.environ() if environ is None else environ,
            files=self.files,
            sleep=self.clock.sleep,
            monotonic=self.clock.monotonic,
        )

    def stack(self, unit: str) -> str:
        region = "useast1" if unit == "cert" else "useast2"
        return f"stk-{region}-oecalc-{unit}-{self.env}"

    def cfn_of(self, unit: str) -> FakeCfn:
        return self.east1 if unit == "cert" else self.east2

    def operations(self, name: str) -> list[str]:
        return [entry[1] for entry in self.log if entry[0] == name]


@pytest.fixture
def world() -> World:
    return World()


# ---------------------------------------------------------------------------
# Change set guard
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "change",
    [
        add_change("Add"),
        add_change("Add", "True"),
        add_change("Modify", "False"),
    ],
)
def test_guard_allows_add_and_in_place_modify(change: dict[str, Any]) -> None:
    assert cfn_deploy.guard_changes([change]) == []


@pytest.mark.parametrize(
    "change",
    [
        add_change("Modify", "True"),
        add_change("Modify", "Conditional"),
        add_change("Modify"),
        add_change("Remove"),
        add_change("Import"),
        add_change("Dynamic"),
        add_change("Unknown"),
        {"Type": "Resource", "ResourceChange": {"LogicalResourceId": "X"}},
        {"Type": "Other", "ResourceChange": {"Action": "Add"}},
        {"Type": "Resource"},
    ],
)
def test_guard_refuses_everything_else(change: dict[str, Any]) -> None:
    assert len(cfn_deploy.guard_changes([change])) == 1


def test_guard_has_an_empty_allow_list() -> None:
    assert not hasattr(cfn_deploy, "REPLACEMENT_ALLOWED_TYPES")
    refused = cfn_deploy.guard_changes([add_change("Modify", "True", "AWS::Lambda::Function")])
    assert refused and "AWS::Lambda::Function" in refused[0]


def test_change_set_is_paged_through_next_token(world: World) -> None:
    changes = [add_change("Add") for _ in range(5)]
    world.east2.scripted_changes[world.stack("auth")] = changes
    world.east2.change_sets[(world.stack("auth"), "cs")] = {"changes": changes}
    page = world.deployer().describe_change_set(world.east2, world.stack("auth"), "cs")
    assert len(page["Changes"]) == 5


# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
def test_deploy_runs_the_four_stacks_in_order_and_prints_the_summary(
    world: World, capsys: pytest.CaptureFixture[str]
) -> None:
    world.deployer().deploy()
    assert world.operations("execute_change_set") == [
        world.stack("auth"),
        world.stack("cert"),
        world.stack("auth-bff"),
        world.stack("frontend"),
    ]
    out = capsys.readouterr().out
    assert f"COGNITO_USER_POOL_ID={POOL}" in out
    assert f"COGNITO_APP_CLIENT_ID={CLIENT}" in out
    assert f"COGNITO_PUBLIC_APP_CLIENT_ID={PUBLIC_CLIENT}" in out
    assert CLIENT != PUBLIC_CLIENT
    lines = out.splitlines()
    assert lines[-3:] == [
        f"COGNITO_USER_POOL_ID={POOL}",
        f"COGNITO_APP_CLIENT_ID={CLIENT}",
        f"COGNITO_PUBLIC_APP_CLIENT_ID={PUBLIC_CLIENT}",
    ]
    assert EMAIL not in out and ZONE not in out


def test_summary_fails_naming_the_output_when_the_public_client_output_is_missing(world: World) -> None:
    del world.east2.outputs_on_create[world.stack("auth")]["PublicAppClientId"]
    with pytest.raises(cfn_deploy.DeployError, match="PublicAppClientId"):
        world.deployer().deploy()


def test_change_sets_carry_tags_capabilities_and_no_disable_rollback(world: World) -> None:
    world.deployer().deploy()
    created = world.east2.created[0]
    assert created["ChangeSetType"] == "CREATE"
    assert {"Key": "env-type", "Value": "dev"} in created["Tags"]
    assert "CAPABILITY_AUTO_EXPAND" in created["Capabilities"]
    assert all("DisableRollback" not in call for call in world.east2.created + world.east1.created)


def test_consumers_receive_the_producer_outputs_read_in_the_producer_region(world: World) -> None:
    world.deployer().deploy()
    bff = {p["ParameterKey"]: p["ParameterValue"] for p in world.east2.created[1]["Parameters"]}
    assert bff["AppClientId"] == CLIENT
    assert bff["ClientSecretName"] == "sm-useast2-oecalc-auth-app-client-dev"
    assert bff["ClientSecretArn"].startswith("arn:aws:secretsmanager:")
    assert bff["AlertEmail"] == EMAIL
    frontend = {p["ParameterKey"]: p["ParameterValue"] for p in world.east2.created[2]["Parameters"]}
    assert frontend["CertificateArn"] == CERT_ARN
    assert frontend["BffFunctionName"] == "fnc-useast2-oecalc-auth-bff-dev"
    assert frontend["BffFunctionUrlHost"] == "abc.lambda-url.us-east-2.on.aws"
    assert frontend["HostedZoneId"] == ZONE


@pytest.mark.parametrize("replacement", [add_change("Modify", "True"), add_change("Remove"), add_change("Modify")])
def test_refused_change_set_is_printed_deleted_and_stops_the_run(
    world: World, replacement: dict[str, Any], capsys: pytest.CaptureFixture[str]
) -> None:
    world.east2.scripted_changes[world.stack("auth")] = [add_change("Add"), replacement]
    with pytest.raises(cfn_deploy.DeployError):
        world.deployer().deploy()
    assert world.operations("execute_change_set") == []
    assert world.operations("delete_change_set") == [world.stack("auth")]
    assert world.operations("delete_stack") == [world.stack("auth")]
    assert "Res" in capsys.readouterr().out


def test_refused_update_change_set_keeps_the_existing_stack(world: World) -> None:
    world.east2.add_stack(world.stack("auth"), "CREATE_COMPLETE")
    world.east2.scripted_changes[world.stack("auth")] = [add_change("Remove")]
    with pytest.raises(cfn_deploy.DeployError):
        world.deployer().deploy()
    assert world.operations("delete_change_set") == [world.stack("auth")]
    assert world.operations("delete_stack") == []
    assert world.east2.created[0]["ChangeSetType"] == "UPDATE"


@pytest.mark.parametrize(
    "status",
    [
        "ROLLBACK_COMPLETE",
        "ROLLBACK_FAILED",
        "DELETE_FAILED",
        "UPDATE_IN_PROGRESS",
        "CREATE_IN_PROGRESS",
        "DELETE_IN_PROGRESS",
        "UPDATE_ROLLBACK_FAILED",
    ],
)
def test_bad_stack_status_is_refused_before_a_change_set(world: World, status: str) -> None:
    world.east2.add_stack(world.stack("auth"), status)
    with pytest.raises(cfn_deploy.DeployError, match=status):
        world.deployer().deploy()
    assert world.operations("create_change_set") == []


def test_no_changes_deletes_the_change_set_and_executes_nothing(world: World) -> None:
    for unit in ("auth", "cert", "auth-bff", "frontend"):
        world.cfn_of(unit).add_stack(
            world.stack(unit),
            "UPDATE_COMPLETE",
            outputs=world.cfn_of(unit).outputs_on_create[world.stack(unit)],
        )
        world.cfn_of(unit).no_changes.add(world.stack(unit))
    world.deployer().deploy()
    assert world.operations("execute_change_set") == []
    assert len(world.operations("delete_change_set")) == 4


def test_dev_recovery_deletes_only_the_rollback_complete_stack(world: World) -> None:
    world.east2.add_stack(world.stack("auth"), "ROLLBACK_COMPLETE")
    world.east2.add_stack(world.stack("frontend"), "CREATE_COMPLETE")
    world.deployer().deploy(recover=True)
    assert world.operations("delete_stack") == [world.stack("auth")]
    assert world.east2.created[0]["ChangeSetType"] == "CREATE"


def test_recovery_is_refused_in_prod() -> None:
    prod = World("prod")
    prod.east2.add_stack(prod.stack("auth"), "ROLLBACK_COMPLETE")
    with pytest.raises(cfn_deploy.DeployError, match="dev"):
        prod.deployer().deploy(recover=True)
    assert prod.operations("delete_stack") == []


def test_recovery_never_touches_other_failed_states(world: World) -> None:
    world.east2.add_stack(world.stack("auth"), "DELETE_FAILED")
    with pytest.raises(cfn_deploy.DeployError):
        world.deployer().deploy(recover=True)
    assert world.operations("delete_stack") == []


def test_certificate_must_be_issued_for_the_environment_host(world: World) -> None:
    world.acm.status = "PENDING_VALIDATION"
    with pytest.raises(cfn_deploy.DeployError, match="ISSUED"):
        world.deployer().deploy()
    assert world.stack("frontend") not in world.operations("create_change_set")


def test_certificate_for_another_domain_is_refused(world: World) -> None:
    world.acm.domain = "other.example.test"
    with pytest.raises(cfn_deploy.DeployError, match="DomainName"):
        world.deployer().deploy()


def test_hosted_zone_must_contain_the_domain(world: World) -> None:
    world.route53.name = "other-zone.test."
    with pytest.raises(cfn_deploy.DeployError, match="hosted zone"):
        world.deployer().deploy()
    assert world.operations("create_change_set") == []


@pytest.mark.parametrize("missing", ["ROUTE53_ZONE_ID", "SUPPORT_EMAIL"])
def test_missing_variable_is_named_and_stops_before_any_call(world: World, missing: str) -> None:
    environ = world.environ()
    del environ[missing]
    with pytest.raises(cfn_deploy.DeployError, match=missing):
        world.deployer(environ).deploy()
    assert world.log == []


def test_prod_requires_the_web_acl_variable() -> None:
    prod = World("prod")
    environ = prod.environ()
    del environ["WAF_WEB_ACL_ARN"]
    with pytest.raises(cfn_deploy.DeployError, match="WAF_WEB_ACL_ARN"):
        prod.deployer(environ).deploy()
    assert prod.log == []


def test_parameter_file_of_another_environment_is_refused(world: World) -> None:
    def other_env(path: Path) -> str:
        text = world.files(path)
        return text.replace('"EnvType": "dev"', '"EnvType": "prod"') if path.suffix == ".json" else text

    deployer = world.deployer()
    deployer.files = other_env
    with pytest.raises(cfn_deploy.DeployError, match="EnvType"):
        deployer.deploy()
    assert world.log == []


def test_stack_that_never_finishes_times_out(world: World) -> None:
    world.east2.stuck.add(world.stack("auth"))
    with pytest.raises(cfn_deploy.DeployError, match="timed out"):
        world.deployer().deploy()


def test_oversized_template_is_refused(world: World) -> None:
    deployer = world.deployer()
    deployer.files = lambda path: "x" * 60000 if path.suffix == ".yaml" else world.files(path)
    with pytest.raises(cfn_deploy.DeployError, match="51200"):
        deployer.deploy()


# SAM ---------------------------------------------------------------------------
def test_sam_stack_is_built_and_packaged_to_the_bucket_from_ssm(world: World) -> None:
    world.deployer().deploy()
    build, package = world.commands
    assert build[:2] == ["sam", "build"]
    assert package[:2] == ["sam", "package"]
    assert package[package.index("--s3-bucket") + 1] == BUCKET
    assert package[package.index("--s3-prefix") + 1] == "over-engineered-simple-calculator-webpage/dev"
    assert "--resolve-s3" not in package
    body = world.east2.created[1]["TemplateBody"]
    assert body == PACKAGED


def test_missing_ssm_parameter_stops_before_sam_runs(world: World) -> None:
    world.ssm.value = None
    with pytest.raises(cfn_deploy.DeployError, match="artifacts bucket"):
        world.deployer().deploy()
    assert world.commands == []
    assert world.stack("auth-bff") not in world.operations("create_change_set")


def test_missing_bucket_stops_before_sam_runs(world: World) -> None:
    world.s3.bucket_exists = False
    with pytest.raises(cfn_deploy.DeployError, match="bucket"):
        world.deployer().deploy()
    assert world.commands == []


def test_sam_failure_stops_the_run(world: World) -> None:
    world.sam_failure = True
    with pytest.raises(cfn_deploy.DeployError, match="sam"):
        world.deployer().deploy()


def test_code_sha_mismatch_is_refused(world: World) -> None:
    world.lambda_.sha = "different"
    with pytest.raises(cfn_deploy.DeployError, match="CodeSha256"):
        world.deployer().deploy()


# Prod ---------------------------------------------------------------------------
def test_prod_sets_termination_protection_stack_policy_and_prints_drift(
    capsys: pytest.CaptureFixture[str],
) -> None:
    prod = World("prod")
    prod.east2.add_stack(prod.stack("auth"), "CREATE_COMPLETE")
    prod.east2.outputs_on_create[prod.stack("auth")]["UserPoolId"] = POOL
    prod.east2.drift = [
        {
            "LogicalResourceId": "UserPool",
            "StackResourceDriftStatus": "MODIFIED",
            "ResourceType": "AWS::Cognito::UserPool",
        }
    ]
    prod.deployer().deploy()
    protections = [e for e in prod.log if e[0] == "termination_protection"]
    assert {e[1] for e in protections} == {prod.stack(u) for u in ("auth", "cert", "auth-bff", "frontend")}
    assert all(e[2] == "True" for e in protections)
    policy = json.loads(prod.east2.policies[prod.stack("auth")])
    assert policy == json.loads(cfn_deploy.STACK_POLICY_FILE.read_text(encoding="utf-8"))
    out = capsys.readouterr().out
    assert "drift" in out.lower() and "UserPool" in out


def test_dev_has_no_protection_policy_or_drift_report(world: World) -> None:
    world.deployer().deploy()
    assert world.operations("termination_protection") == []
    assert world.operations("set_stack_policy") == []
    assert world.operations("detect_stack_drift") == []


def test_stack_policy_file_denies_replace_and_delete_of_the_critical_resources() -> None:
    policy = cfn_deploy.load_stack_policy()
    allow, deny = policy["Statement"]
    assert allow["Effect"] == "Allow" and allow["Action"] == "Update:*"
    assert deny["Effect"] == "Deny"
    assert set(deny["Action"]) == {"Update:Replace", "Update:Delete"}
    assert set(deny["Resource"]) == {
        f"LogicalResourceId/{name}"
        for name in ("UserPool", "AppClient", "PublicAppClient", "AppClientSecret", "Distribution", "WebBucket")
    }


# ---------------------------------------------------------------------------
# Destroy
# ---------------------------------------------------------------------------
def deployed_world() -> World:
    world = World()
    for unit in ("auth", "cert", "auth-bff", "frontend"):
        cfn = world.cfn_of(unit)
        cfn.add_stack(world.stack(unit), "CREATE_COMPLETE", outputs=cfn.outputs_on_create[world.stack(unit)])
    world.east2.stacks[world.stack("frontend")]["resources"] = [
        resource("WebBucket", "AWS::S3::Bucket", "web-bucket"),
        resource("Distribution", "AWS::CloudFront::Distribution", "EFAKE"),
    ]
    world.s3.versions = [{"Key": "index.html", "VersionId": "v1"}]
    world.secrets = FakeSecrets({"Name": "x", "DeletedDate": "2026-10-24"})
    return world


def test_destroy_deletes_in_reverse_order_and_empties_the_bucket_in_dev() -> None:
    world = deployed_world()
    world.deployer().destroy("destroy")
    assert world.operations("delete_stack") == [
        world.stack("frontend"),
        world.stack("auth-bff"),
        world.stack("cert"),
        world.stack("auth"),
    ]
    assert world.s3.deleted == [[{"Key": "index.html", "VersionId": "v1"}]]


def test_bucket_is_emptied_before_the_frontend_stack_is_deleted() -> None:
    world = deployed_world()
    seen: list[int] = []
    original = world.east2.delete_stack

    def spy(StackName: str) -> dict[str, Any]:
        seen.append(len(world.s3.deleted))
        return original(StackName=StackName)

    world.east2.delete_stack = spy  # type: ignore[method-assign]
    world.deployer().destroy("destroy")
    assert seen[0] == 1


def test_destroy_is_refused_for_prod_before_any_call() -> None:
    prod = World("prod")
    with pytest.raises(cfn_deploy.DeployError, match="dev"):
        prod.deployer().destroy("destroy")
    assert prod.log == [] and prod.s3.deleted == []


def test_empty_bucket_helper_refuses_other_environments() -> None:
    prod = World("prod")
    with pytest.raises(cfn_deploy.DeployError):
        prod.deployer().empty_bucket("web-bucket")
    assert prod.s3.deleted == []


def test_pending_deletion_secret_is_force_deleted_after_the_auth_stack() -> None:
    world = deployed_world()
    world.deployer().destroy("destroy")
    assert world.secrets.forced == ["sm-useast2-oecalc-auth-app-client-dev"]


@pytest.mark.parametrize("secret", [None, {"Name": "x"}])
def test_secret_that_is_absent_or_active_is_not_force_deleted(
    secret: dict[str, Any] | None,
) -> None:
    world = deployed_world()
    world.secrets = FakeSecrets(secret)
    world.deployer().destroy("destroy")
    assert world.secrets.forced == []


def test_destroy_plan_changes_nothing_and_shows_the_user_count(
    capsys: pytest.CaptureFixture[str],
) -> None:
    world = deployed_world()
    world.deployer().destroy("plan")
    assert world.operations("delete_stack") == [] and world.s3.deleted == []
    out = capsys.readouterr().out
    assert "7" in out and "users" in out.lower()
    assert world.secrets.forced == []


def test_destroy_turns_termination_protection_off() -> None:
    world = deployed_world()
    world.east2.stacks[world.stack("auth")]["protection"] = True
    world.deployer().destroy("destroy")
    assert ("termination_protection", world.stack("auth"), "False") in world.log


def test_destroy_stops_when_the_bucket_cannot_be_emptied() -> None:
    world = deployed_world()
    world.s3.delete_errors = [{"Key": "index.html", "Code": "AccessDenied", "Message": "no"}]
    with pytest.raises(cfn_deploy.DeployError, match="empty"):
        world.deployer().destroy("destroy")
    assert world.operations("delete_stack") == []


def test_destroy_refuses_a_stack_in_progress() -> None:
    world = deployed_world()
    world.east2.stacks[world.stack("auth-bff")]["status"] = "UPDATE_IN_PROGRESS"
    with pytest.raises(cfn_deploy.DeployError, match="IN_PROGRESS"):
        world.deployer().destroy("destroy")
    assert world.operations("delete_stack") == []


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------
def run_main(world: World, argv: list[str]) -> int:
    return cfn_deploy.main(
        argv,
        factory=world.factory(),
        runner=world.runner,
        environ=world.environ(),
        files=world.files,
        sleep=world.clock.sleep,
        monotonic=world.clock.monotonic,
    )


def test_main_deploy_returns_0_and_1_on_refusal(world: World) -> None:
    assert run_main(world, ["deploy", "--env", "dev"]) == 0
    refused = World()
    refused.east2.scripted_changes[refused.stack("auth")] = [add_change("Remove")]
    assert run_main(refused, ["deploy", "--env", "dev"]) == 1


def test_main_output_prints_one_stack_output(world: World, capsys: pytest.CaptureFixture[str]) -> None:
    run_main(world, ["deploy", "--env", "dev"])
    capsys.readouterr()
    assert run_main(world, ["output", "--env", "dev", "--unit", "auth", "--key", "UserPoolId"]) == 0
    assert capsys.readouterr().out.strip() == POOL
    assert run_main(world, ["output", "--env", "dev", "--unit", "auth", "--key", "Nope"]) == 1


def test_main_destroy_only_accepts_dev(world: World) -> None:
    with pytest.raises(SystemExit) as exc:
        run_main(world, ["destroy", "--env", "prod", "--mode", "plan"])
    assert exc.value.code == 2


def test_main_destroy_dev_runs(world: World) -> None:
    world.east2.add_stack(world.stack("auth"), "CREATE_COMPLETE")
    assert run_main(world, ["destroy", "--env", "dev", "--mode", "destroy"]) == 0


# ---------------------------------------------------------------------------
# Review fixes: gaps of the guard, waits, error taxonomy, exposure, input validation
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("position", [2, 3, 4])
@pytest.mark.parametrize(
    "bad", [add_change("Remove"), add_change("Modify", "True"), add_change("Modify", "Conditional")]
)
def test_violation_on_a_later_page_is_refused(world: World, position: int, bad: dict[str, Any]) -> None:
    changes = [add_change("Add") for _ in range(5)]
    changes[position] = bad
    world.east2.scripted_changes[world.stack("auth")] = changes
    with pytest.raises(cfn_deploy.DeployError, match="guard refused"):
        world.deployer().deploy()
    assert world.operations("execute_change_set") == []
    assert world.operations("delete_change_set") == [world.stack("auth")]


def test_failed_change_set_other_than_no_changes_stops_the_run(world: World) -> None:
    world.east2.change_set_state[world.stack("auth")] = ("FAILED", "Parameter X is invalid in 123456789012")
    with pytest.raises(cfn_deploy.DeployError, match="failed") as raised:
        world.deployer().deploy()
    assert "123456789012" not in str(raised.value)
    assert world.operations("execute_change_set") == []


def test_change_set_that_never_finishes_times_out(world: World) -> None:
    world.east2.change_set_state[world.stack("auth")] = ("CREATE_PENDING", "")
    with pytest.raises(cfn_deploy.DeployError, match="timed out waiting for the change set"):
        world.deployer().deploy()
    assert world.clock.now >= cfn_deploy.CHANGE_SET_TIMEOUT_SECONDS


@pytest.mark.parametrize("existing", [True, False])
def test_deploy_waits_for_the_execution_not_for_a_stale_status(world: World, existing: bool) -> None:
    for unit in ("auth", "cert", "auth-bff", "frontend"):
        cfn = world.cfn_of(unit)
        cfn.lag_polls = 3
        if existing:
            cfn.add_stack(world.stack(unit), "UPDATE_COMPLETE", outputs=cfn.outputs_on_create[world.stack(unit)])
    world.deployer().deploy()
    assert world.east2.stale_served == 0 and world.east1.stale_served == 0
    assert len(world.operations("execute_change_set")) == 4


def test_execution_wait_uses_the_change_set_id_so_a_consumed_create_still_resolves(world: World) -> None:
    world.deployer().deploy()
    assert world.east2.consumed
    with pytest.raises(ClientError, match="ChangeSetNotFoundException"):
        world.east2.describe_change_set(
            StackName=world.stack("auth"), ChangeSetName=world.east2.created[0]["ChangeSetName"]
        )


@pytest.mark.parametrize(
    ("kind", "status", "passes"),
    [
        ("CREATE", "CREATE_COMPLETE", True),
        ("CREATE", "CREATE_IN_PROGRESS", True),
        ("CREATE", "ROLLBACK_COMPLETE", False),
        ("UPDATE", "UPDATE_COMPLETE", False),
    ],
)
def test_change_set_gone_during_the_execution_wait(
    world: World, monkeypatch: pytest.MonkeyPatch, kind: str, status: str, passes: bool
) -> None:
    entry = world.deployer().entry_of("auth")
    world.east2.add_stack(entry["stack"], status)
    world.east2.change_set_ids["gone"] = (entry["stack"], "x")
    world.east2.consumed.add(entry["stack"])

    def missing(**_: str) -> dict[str, str]:
        raise client_error("ChangeSetNotFoundException")

    monkeypatch.setattr(world.east2, "describe_change_set", missing)
    deployer = world.deployer()
    if passes:
        deployer.wait_execution(entry, "gone", 60, kind)
    else:
        with pytest.raises(cfn_deploy.DeployError, match="cannot read the execution"):
            deployer.wait_execution(entry, "gone", 60, kind)


def test_failed_execution_is_reported_with_the_failed_events(world: World, capsys: pytest.CaptureFixture[str]) -> None:
    world.east2.failed_execution.add(world.stack("auth"))
    world.east2.events = [
        {"LogicalResourceId": "UserPool", "ResourceStatus": "CREATE_FAILED", "ResourceStatusReason": "no"}
    ]
    with pytest.raises(cfn_deploy.DeployError, match="ended in"):
        world.deployer().deploy()
    assert "UserPool CREATE_FAILED" in capsys.readouterr().out


def test_recovery_waits_for_the_delete_not_for_a_stale_status(world: World) -> None:
    world.east2.delete_lag = 2
    world.east2.add_stack(world.stack("auth"), "ROLLBACK_COMPLETE")
    world.deployer().deploy(recover=True)
    assert world.east2.created[0]["ChangeSetType"] == "CREATE"


def test_destroy_waits_for_the_delete_not_for_a_stale_status() -> None:
    world = deployed_world()
    world.east2.delete_lag = 2
    world.east1.delete_lag = 2
    world.deployer().destroy("destroy")
    assert world.east2.stacks == {} and world.east1.stacks == {}
    assert world.east2.stale_served >= 1


def test_delete_that_stays_in_a_stale_state_fails_after_the_grace_period() -> None:
    world = deployed_world()
    world.east2.delete_lag = 10_000
    with pytest.raises(cfn_deploy.DeployError, match="ended in"):
        world.deployer().destroy("destroy")


def failing(*_args: Any, **_kwargs: Any) -> Any:
    raise client_error("AccessDenied", "denied for 123456789012")


def test_recovery_delete_error_is_a_deploy_error(world: World) -> None:
    world.east2.add_stack(world.stack("auth"), "ROLLBACK_COMPLETE")
    world.east2.delete_stack = failing  # type: ignore[method-assign]
    with pytest.raises(cfn_deploy.DeployError, match="AccessDenied"):
        world.deployer().deploy(recover=True)


@pytest.mark.parametrize("call", ["update_termination_protection", "list_stack_resources", "delete_stack"])
def test_destroy_aws_errors_are_deploy_errors(call: str) -> None:
    world = deployed_world()
    world.east2.stacks[world.stack("auth")]["protection"] = True
    setattr(world.east2, call, failing)
    with pytest.raises(cfn_deploy.DeployError, match="AccessDenied"):
        world.deployer().destroy("destroy")


def test_sam_timeout_is_a_deploy_error(world: World) -> None:
    def timed_out(command: list[str]) -> subprocess.CompletedProcess[str]:
        raise subprocess.TimeoutExpired(command, 1800)

    deployer = world.deployer()
    deployer.runner = timed_out
    with pytest.raises(cfn_deploy.DeployError, match="timed out"):
        deployer.deploy()


def test_unknown_profile_exits_1_with_a_message(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def no_profile(profile: str | None) -> Any:
        raise ProfileNotFound(profile=profile)

    monkeypatch.setattr(cfn_deploy, "make_client_factory", no_profile)
    code = cfn_deploy.main(["output", "--env", "dev", "--unit", "auth", "--key", "K", "--profile", "nope"])
    assert code == 1
    assert "::error::" in capsys.readouterr().out


# Exposure -----------------------------------------------------------------------
def test_destroy_does_not_print_the_bucket_name(capsys: pytest.CaptureFixture[str]) -> None:
    world = deployed_world()
    world.deployer().destroy("destroy")
    out = capsys.readouterr().out
    assert "web-bucket" not in out
    assert "1 versions removed" in out


def test_failed_events_hide_account_ids_and_the_support_email(world: World, capsys: pytest.CaptureFixture[str]) -> None:
    world.east2.failed_execution.add(world.stack("auth"))
    world.east2.events = [
        {
            "LogicalResourceId": "Topic",
            "ResourceStatus": "CREATE_FAILED",
            "ResourceStatusReason": f"bad endpoint {EMAIL} in 123456789012",
        }
    ]
    with pytest.raises(cfn_deploy.DeployError):
        world.deployer().deploy()
    out = capsys.readouterr().out
    assert EMAIL not in out and "123456789012" not in out and "Topic CREATE_FAILED" in out


def test_main_error_line_hides_the_support_email(world: World, capsys: pytest.CaptureFixture[str]) -> None:
    def leaking(command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(command, 1, "", f"failed for {EMAIL}")

    world.runner = leaking  # type: ignore[method-assign]
    assert run_main(world, ["deploy", "--env", "dev"]) == 1
    assert EMAIL not in capsys.readouterr().out


def test_cognito_identifiers_are_still_printed(world: World, capsys: pytest.CaptureFixture[str]) -> None:
    world.deployer().deploy()
    out = capsys.readouterr().out
    assert POOL in out and CLIENT in out


# Input validation ---------------------------------------------------------------
def with_config(world: World, edit: Callable[[dict[str, Any]], object]) -> cfn_deploy.Deployer:
    def files(path: Path) -> str:
        text = world.files(path)
        if path.name != "dev.json":
            return text
        config = json.loads(text)
        edit(config)
        return json.dumps(config)

    deployer = world.deployer()
    deployer.files = files
    return deployer


@pytest.mark.parametrize("tag", ["team-owner", "project-name", "app-name", "repo-name", "env-type"])
def test_missing_mandatory_tag_is_named(world: World, tag: str) -> None:
    deployer = with_config(world, lambda config: config["Tags"].pop(tag))
    with pytest.raises(cfn_deploy.DeployError, match=tag):
        deployer.deploy()
    assert world.log == []


def test_tag_env_type_must_match_the_environment(world: World) -> None:
    deployer = with_config(world, lambda config: config["Tags"].update({"env-type": "prod"}))
    with pytest.raises(cfn_deploy.DeployError, match="env-type"):
        deployer.deploy()


@pytest.mark.parametrize("key", ["DomainName", "RegionCode", "Context"])
def test_missing_required_parameter_is_named(world: World, key: str) -> None:
    deployer = with_config(world, lambda config: config["Parameters"].pop(key))
    with pytest.raises(cfn_deploy.DeployError, match=key):
        deployer.deploy()
    assert world.log == []


# ---------------------------------------------------------------------------
# Review only and parameters-env
# ---------------------------------------------------------------------------
def review_deployer(world: World, parameters_env: str | None = None) -> cfn_deploy.Deployer:
    environ = world.environ()
    if parameters_env == "prod":
        environ["WAF_WEB_ACL_ARN"] = WAF
        world.route53.name = "nube-segura.com."
    return cfn_deploy.Deployer(
        env=world.env,
        factory=world.factory(),
        runner=world.runner,
        environ=environ,
        files=world.files,
        sleep=world.clock.sleep,
        monotonic=world.clock.monotonic,
        parameters_env=parameters_env,
    )


def test_review_only_never_executes_and_leaves_no_change_set_or_shell(
    world: World, capsys: pytest.CaptureFixture[str]
) -> None:
    review_deployer(world).deploy(review_only=True)
    assert world.operations("create_change_set") == [world.stack(u) for u in ("auth", "cert", "auth-bff", "frontend")]
    assert world.operations("execute_change_set") == []
    assert world.operations("delete_change_set") == world.operations("create_change_set")
    assert world.operations("delete_stack") == world.operations("create_change_set")
    assert world.east2.stacks == {} and world.east1.stacks == {}
    assert world.east2.change_sets == {} and world.east1.change_sets == {}
    assert world.operations("set_stack_policy") == []
    out = capsys.readouterr().out
    assert "COGNITO_USER_POOL_ID" not in out
    assert "R0" in out and "nothing was executed" in out.lower()
    assert EMAIL not in out and ZONE not in out


def test_review_only_keeps_existing_stacks(world: World) -> None:
    world.east2.add_stack(world.stack("auth"), "CREATE_COMPLETE")
    review_deployer(world).deploy(review_only=True)
    assert world.stack("auth") in world.east2.stacks
    assert world.operations("delete_stack") == [world.stack(u) for u in ("cert", "auth-bff", "frontend")]


def test_review_only_still_refuses_and_discards_a_bad_change_set(world: World) -> None:
    world.east2.scripted_changes[world.stack("auth")] = [add_change("Remove")]
    with pytest.raises(cfn_deploy.DeployError, match="guard"):
        review_deployer(world).deploy(review_only=True)
    assert world.operations("execute_change_set") == []
    assert world.east2.change_sets == {}


def test_review_only_discards_the_change_set_when_it_fails(world: World) -> None:
    world.east2.change_set_state[world.stack("auth")] = ("FAILED", "Template error")
    with pytest.raises(cfn_deploy.DeployError, match="failed"):
        review_deployer(world).deploy(review_only=True)
    assert world.operations("delete_change_set") == [world.stack("auth")]
    assert world.operations("delete_stack") == [world.stack("auth")]


def test_review_only_refuses_recovery(world: World) -> None:
    with pytest.raises(cfn_deploy.DeployError, match="recover"):
        review_deployer(world).deploy(recover=True, review_only=True)
    assert world.log == []


def test_producer_outputs_that_do_not_exist_yet_are_placeholders_in_review_only(world: World) -> None:
    review_deployer(world).deploy(review_only=True)
    bff = {p["ParameterKey"]: p["ParameterValue"] for p in world.east2.created[1]["Parameters"]}
    assert bff["AppClientId"] == cfn_deploy.REVIEW_PLACEHOLDER


def test_dev_rehearsal_uses_the_prod_parameter_values(world: World) -> None:
    review_deployer(world, "prod").deploy(review_only=True)
    first = {p["ParameterKey"]: p["ParameterValue"] for p in world.east2.created[0]["Parameters"]}
    assert first["EnvType"] == "prod"
    cert = {p["ParameterKey"]: p["ParameterValue"] for p in world.east1.created[0]["Parameters"]}
    assert cert["DomainName"] == "over-engineered-simple-calculator.nube-segura.com"
    assert {"Key": "env-type", "Value": "prod"} in world.east2.created[0]["Tags"]
    assert world.east2.created[0]["StackName"] == world.stack("auth")
    assert "-prod" not in world.east2.created[0]["StackName"]
    assert world.operations("execute_change_set") == []


def test_dev_with_prod_values_requires_review_only(world: World) -> None:
    with pytest.raises(cfn_deploy.DeployError, match="review-only"):
        review_deployer(world, "prod").deploy()
    assert world.log == []


def test_prod_with_dev_values_is_refused() -> None:
    world = World("prod")
    with pytest.raises(cfn_deploy.DeployError, match="not allowed"):
        review_deployer(world, "dev")


def test_parameters_env_equal_to_env_is_the_default(world: World) -> None:
    review_deployer(world, "dev").deploy(review_only=True)
    first = {p["ParameterKey"]: p["ParameterValue"] for p in world.east2.created[0]["Parameters"]}
    assert first["EnvType"] == "dev"


def test_main_review_only_and_parameters_env(world: World) -> None:
    world.route53.name = "nube-segura.com."
    argv = ["deploy", "--env", "dev", "--review-only", "--parameters-env", "prod"]
    assert (
        cfn_deploy.main(
            argv,
            factory=world.factory(),
            runner=world.runner,
            environ={**world.environ(), "WAF_WEB_ACL_ARN": WAF},
            files=world.files,
            sleep=world.clock.sleep,
            monotonic=world.clock.monotonic,
        )
        == 0
    )
    assert world.operations("execute_change_set") == []
    assert run_main(World(), ["deploy", "--env", "dev", "--parameters-env", "prod"]) == 1
