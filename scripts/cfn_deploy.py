"""CloudFormation (SAM) deploy and destroy driver of the IAC_TOOL=cloudformation path.

Stacks come from templates/stacks.json in order (auth, cert, auth-bff, frontend), each in its own Region.
Every stack is deployed through a change set that a guard inspects before it is executed. The workflow
runs scripts/iac_owner_guard.py first; this script does not repeat that check.

Command line (credentials from the environment or --profile; run from the repository root):

    python scripts/cfn_deploy.py deploy --env dev|prod [--recover-rollback] [--review-only]
                                        [--parameters-env dev|prod] [--profile P]
    python scripts/cfn_deploy.py destroy --env dev --mode plan|destroy [--profile P]
    python scripts/cfn_deploy.py output --env dev|prod --unit auth --key UserPoolId [--profile P]

Exit codes: 0 done; 1 refused or failed (the message says why); 2 bad arguments.
Printed text hides account IDs (12 digits) and the SUPPORT_EMAIL value; the web bucket name is never printed.

deploy     Required variables (names only are validated, values are never printed): ROUTE53_ZONE_ID,
           SUPPORT_EMAIL, and for prod also WAF_WEB_ACL_ARN. GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT name the
           change sets. Parameters come from parameters/<env>.json, the stack tags, those variables and the
           outputs of the producer stacks (read in the producer's Region right before the consumer's change
           set). At the end it prints COGNITO_USER_POOL_ID and COGNITO_APP_CLIENT_ID.
           Change-set guard: Add is allowed; Modify only when Replacement is False; Remove, Import,
           Dynamic and anything unknown are refused; the allow-list of exceptions is empty. A refused change
           set is printed in full and deleted. Stacks in ROLLBACK_*, DELETE_FAILED, *_IN_PROGRESS and
           other unexpected states are refused; --disable-rollback is never used.
           --recover-rollback (dev only) deletes a stack that is in ROLLBACK_COMPLETE, and only that one,
           then creates it again.
           --review-only creates the change sets with the same checks, parameter loading, guard and masking,
           prints the guarded summary of each and never executes one. Every change set is then deleted, and
           so is the empty REVIEW_IN_PROGRESS shell its creation left, so no stack remains. Producer outputs
           that do not exist yet are replaced by a placeholder (the printed change set is then indicative).
           It is not combined with --recover-rollback and it does not attach protection or verify code.
           --parameters-env (default: the value of --env) picks parameters/<name>.json, the EnvType and
           env-type tag it must hold, and the variables that are required. Stack names, Regions and the
           target account still come from --env. Allowed pairs (env, parameters-env): (dev, dev),
           (prod, prod) and (dev, prod), the last one only with --review-only (rehearsal of prod values).
           prod also enables termination protection, attaches templates/stack-policy-prod.json (no replace
           or delete of the user pool, app client, secret, distribution and web bucket) and prints a
           read-only drift report of the stacks that already exist. The change-set guard refuses every
           replacement and removal, so a replacement or removal in prod needs a deliberate manual change
           set outside this script, with a separate authorization. The policy is attached again after each
           successful stack deploy.
destroy    dev only. plan lists what exists and the Cognito user count and changes nothing. destroy empties
           the web bucket (dev only), deletes the stacks in reverse order (frontend, auth-bff, cert, auth)
           and force-deletes the client secret if it is left pending deletion, so the name can be reused.
output     Prints one output of one stack, for the later workflow steps.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from botocore.exceptions import BotoCoreError, ClientError

from iac_common import (
    ENVIRONMENTS,
    REPO_ROOT,
    STACKS_FILE,
    ClientFactory,
    ConfigError,
    error_code,
    is_missing_stack,
    load_stacks,
    make_client_factory,
)

BUILD_DIR = REPO_ROOT / ".aws-sam"
PARAMETERS_DIR = REPO_ROOT / "parameters"
STACK_POLICY_FILE = REPO_ROOT / "templates" / "stack-policy-prod.json"
SAMCONFIG = REPO_ROOT / "samconfig.toml"

CAPABILITIES = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]
TEMPLATE_BODY_LIMIT = 51200
POLL_SECONDS = 15
CHANGE_SET_POLL_SECONDS = 5
CHANGE_SET_TIMEOUT_SECONDS = 10 * 60
STACK_TIMEOUT_SECONDS = 60 * 60
CERT_TIMEOUT_SECONDS = 30 * 60
DRIFT_TIMEOUT_SECONDS = 10 * 60
DELETE_SETTLE_SECONDS = 60
REVIEW_PLACEHOLDER = "review-only-placeholder"
NO_CHANGES_MARKERS = ("didn't contain changes", "No updates are to be performed")

OK_TO_DEPLOY = frozenset({"CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE", "IMPORT_COMPLETE"})
TAG_PARAMETERS = {
    "TagTeamOwner": "team-owner",
    "TagProjectName": "project-name",
    "TagAppName": "app-name",
    "TagRepoName": "repo-name",
}
REQUIRED_TAGS = ("team-owner", "project-name", "app-name", "repo-name", "env-type")
REQUIRED_PARAMETERS = ("EnvType", "Context", "RegionCode", "DomainName")
HIDDEN_VARIABLES = ("SUPPORT_EMAIL",)
ENV_PARAMETERS = {
    "HostedZoneId": "ROUTE53_ZONE_ID",
    "AlertEmail": "SUPPORT_EMAIL",
    "WebAclArn": "WAF_WEB_ACL_ARN",
}
# unit -> (parameter, producer unit, producer output key)
CONSUMES: dict[str, list[tuple[str, str, str]]] = {
    "auth-bff": [
        ("AppClientId", "auth", "AppClientId"),
        ("ClientSecretName", "auth", "AppClientSecretName"),
        ("ClientSecretArn", "auth", "AppClientSecretArn"),
    ],
    "frontend": [
        ("CertificateArn", "cert", "CertificateArn"),
        ("BffFunctionName", "auth-bff", "FunctionName"),
        ("BffFunctionUrlHost", "auth-bff", "FunctionUrlHost"),
    ],
}

ALLOWED_PARAMETER_PAIRS = frozenset({("dev", "dev"), ("prod", "prod"), ("dev", "prod")})

Runner = Callable[[list[str]], "subprocess.CompletedProcess[str]"]
FileReader = Callable[[Path], str]


class DeployError(Exception):
    """A stack could not be deployed, destroyed or checked safely."""


def mask(text: str, hidden: tuple[str, ...] = ()) -> str:
    """Hide account IDs (12 digits) and the given values in messages that come from other tools."""
    for value in hidden:
        if value:
            text = text.replace(value, "***")
    return re.sub(r"\b\d{12}\b", "************", text)


def hidden_values(environ: Mapping[str, str]) -> tuple[str, ...]:
    """The values of the variables that must never be printed."""
    return tuple(environ.get(name, "") for name in HIDDEN_VARIABLES)


def error_label(exc: Exception) -> str:
    """A short, value-free description of an AWS error: the error code, or the exception type."""
    return error_code(exc) if isinstance(exc, ClientError) and error_code(exc) else type(exc).__name__


def default_runner(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, check=False, timeout=1800)


def read_utf8(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def template_parameters(template_text: str) -> dict[str, str | None]:
    """Names of the top-level Parameters of a template and their Default (None when there is none).

    The templates of this repository keep a fixed layout (two-space indentation), so no YAML library is
    needed (CloudFormation short-form tags such as !Ref do not load with a safe loader).
    """
    names: dict[str, str | None] = {}
    inside = False
    current: str | None = None
    for line in template_text.splitlines():
        if re.match(r"^\S", line):
            inside = line.startswith("Parameters:")
            current = None
            continue
        if not inside:
            continue
        key = re.match(r"^  ([A-Za-z0-9]+):\s*$", line)
        if key:
            current = key.group(1)
            names[current] = None
            continue
        default = re.match(r'^    Default:\s*"?(.*?)"?\s*$', line)
        if default and current:
            names[current] = default.group(1)
    return names


def load_stack_policy() -> dict[str, Any]:
    """The prod stack policy, checked for the shape this script relies on."""
    policy = json.loads(STACK_POLICY_FILE.read_text(encoding="utf-8"))
    statements = policy.get("Statement") if isinstance(policy, dict) else None
    if not (isinstance(statements, list) and len(statements) == 2):
        raise DeployError("stack-policy-prod.json must hold one Allow and one Deny statement")
    allow, deny = statements
    if allow.get("Effect") != "Allow" or deny.get("Effect") != "Deny":
        raise DeployError("stack-policy-prod.json: expected Allow first and Deny second")
    return dict(policy)


def guard_changes(changes: list[dict[str, Any]]) -> list[str]:
    """The violations of the change set guard (an empty list means it is safe to execute).

    Add is allowed. Modify is allowed only when Replacement is explicitly False. Everything else (Remove,
    Import, Dynamic, an unknown action or an unexpected entry) is refused. There are no exceptions.
    """
    violations: list[str] = []
    for change in changes:
        detail = change.get("ResourceChange")
        if change.get("Type") != "Resource" or not isinstance(detail, dict):
            violations.append(f"Unexpected change entry: {json.dumps(change, default=str)[:200]}")
            continue
        action = detail.get("Action")
        label = f"{detail.get('ResourceType')} {detail.get('LogicalResourceId')}"
        if action == "Add":
            continue
        if action == "Modify":
            replacement = detail.get("Replacement")
            if replacement != "False":
                violations.append(f"Modify with Replacement={replacement}: {label}")
            continue
        violations.append(f"{action} is not allowed: {label}")
    return violations


class Deployer:
    """Deploys, destroys and reads the stacks of one environment through injected AWS clients."""

    def __init__(
        self,
        env: str,
        factory: ClientFactory,
        runner: Runner = default_runner,
        environ: Mapping[str, str] | None = None,
        files: FileReader = read_utf8,
        sleep: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic,
        profile: str | None = None,
        stacks_file: Path = STACKS_FILE,
        parameters_env: str | None = None,
    ) -> None:
        self.env = env
        self.parameters_env = parameters_env or env
        if (env, self.parameters_env) not in ALLOWED_PARAMETER_PAIRS:
            raise DeployError(f"--parameters-env {self.parameters_env} is not allowed with --env {env}")
        self.factory = factory
        self.runner = runner
        self.environ: Mapping[str, str] = os.environ if environ is None else environ
        self.files = files
        self.sleep = sleep
        self.monotonic = monotonic
        self.profile = profile
        try:
            self.data, self.entries = load_stacks(env, stacks_file)
        except ConfigError as exc:
            raise DeployError(str(exc)) from exc
        self.code_uri: dict[str, str] = {}

    # -- small readers ------------------------------------------------------
    def redact(self, text: str) -> str:
        return mask(text, hidden_values(self.environ))

    def cfn(self, entry: dict[str, Any]) -> Any:
        return self.factory("cloudformation", str(entry["region"]))

    def entry_of(self, unit: str) -> dict[str, Any]:
        for entry in self.entries:
            if entry["unit"] == unit:
                return entry
        raise DeployError(f"unknown unit {unit}")

    def describe(self, entry: dict[str, Any]) -> dict[str, Any] | None:
        try:
            stacks = self.cfn(entry).describe_stacks(StackName=entry["stack"])["Stacks"]
        except ClientError as exc:
            if is_missing_stack(exc):
                return None
            raise DeployError(f"cannot describe stack {entry['stack']}: {error_code(exc)}") from exc
        except (BotoCoreError, KeyError) as exc:
            raise DeployError(f"cannot describe stack {entry['stack']}: {type(exc).__name__}") from exc
        if not stacks:
            raise DeployError(f"malformed describe-stacks answer for {entry['stack']}")
        return dict(stacks[0])

    def status(self, entry: dict[str, Any]) -> str | None:
        stack = self.describe(entry)
        return None if stack is None else str(stack["StackStatus"])

    def outputs(self, entry: dict[str, Any]) -> dict[str, str]:
        stack = self.describe(entry)
        if stack is None:
            raise DeployError(f"stack {entry['stack']} does not exist")
        return {o["OutputKey"]: o["OutputValue"] for o in stack.get("Outputs", [])}

    def output_of(self, unit: str, key: str) -> str:
        outputs = self.outputs(self.entry_of(unit))
        if key not in outputs:
            raise DeployError(f"stack of unit {unit} has no output {key}")
        return outputs[key]

    # -- configuration ------------------------------------------------------
    def load_parameters(self) -> dict[str, Any]:
        """parameters/<parameters-env>.json, refused when its EnvType is another environment."""
        path = PARAMETERS_DIR / f"{self.parameters_env}.json"
        try:
            config = json.loads(self.files(path))
            parameters, tags = config["Parameters"], config["Tags"]
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise DeployError(f"cannot read {path.name}: {exc}") from exc
        if not isinstance(parameters, dict) or not isinstance(tags, dict):
            raise DeployError(f"{path.name}: Parameters and Tags must be objects")
        missing = [f"Parameters.{k}" for k in REQUIRED_PARAMETERS if k not in parameters]
        missing += [f"Tags.{k}" for k in REQUIRED_TAGS if k not in tags]
        if missing:
            raise DeployError(f"{path.name} lacks required keys: {', '.join(missing)}")
        expected = self.parameters_env
        if parameters["EnvType"] != expected:
            raise DeployError(f"{path.name} has EnvType '{parameters['EnvType']}': it must be '{expected}'")
        if tags["env-type"] != expected:
            raise DeployError(f"{path.name} has tag env-type '{tags['env-type']}': it must be '{expected}'")
        return dict(config)

    def required_variables(self) -> list[str]:
        names = ["ROUTE53_ZONE_ID", "SUPPORT_EMAIL"]
        return [*names, "WAF_WEB_ACL_ARN"] if self.parameters_env == "prod" else names

    def check_variables(self) -> None:
        missing = [n for n in self.required_variables() if not self.environ.get(n)]
        if missing:
            raise DeployError(f"missing required variables: {', '.join(missing)}")

    def producer_output(self, unit: str, key: str, review_only: bool) -> str:
        """An output of a producer stack; in review-only a missing one becomes a placeholder."""
        if not review_only:
            return self.output_of(unit, key)
        stack = self.describe(self.entry_of(unit))
        outputs = {} if stack is None else {o["OutputKey"]: o["OutputValue"] for o in stack.get("Outputs", [])}
        return str(outputs.get(key, REVIEW_PLACEHOLDER))

    def stack_parameters(
        self, entry: dict[str, Any], config: dict[str, Any], review_only: bool = False
    ) -> list[dict[str, str]]:
        declared = template_parameters(self.files(REPO_ROOT / entry["template"]))
        values: dict[str, str] = {k: str(v) for k, v in config["Parameters"].items()}
        for parameter, tag in TAG_PARAMETERS.items():
            values[parameter] = str(config["Tags"][tag])
        for parameter, variable in ENV_PARAMETERS.items():
            if self.environ.get(variable) is not None:
                values[parameter] = str(self.environ[variable])
        for parameter, unit, key in CONSUMES.get(entry["unit"], []):
            values[parameter] = self.producer_output(unit, key, review_only)
        missing = [n for n, default in declared.items() if n not in values and default is None]
        if missing:
            raise DeployError(f"{entry['template']}: no value for parameters {missing}")
        return [{"ParameterKey": name, "ParameterValue": values[name]} for name in declared if name in values]

    # -- checks before changes ---------------------------------------------
    def check_hosted_zone(self, config: dict[str, Any]) -> None:
        """Read-only: the Route 53 zone must contain the environment host (G-1)."""
        zone_id = self.environ["ROUTE53_ZONE_ID"]
        domain = str(config["Parameters"]["DomainName"])
        try:
            zone = self.factory("route53", "us-east-1").get_hosted_zone(Id=zone_id)["HostedZone"]["Name"]
        except (ClientError, BotoCoreError, KeyError) as exc:
            raise DeployError(f"cannot read the Route 53 hosted zone: {type(exc).__name__}") from exc
        zone_name = str(zone).rstrip(".")
        if domain != zone_name and not domain.endswith(f".{zone_name}"):
            raise DeployError(f"the hosted zone ROUTE53_ZONE_ID does not contain the host {domain}")

    def artifacts_bucket(self, entry: dict[str, Any]) -> str:
        """Name of the shared artifacts bucket, from SSM; a missing parameter or bucket stops the deploy."""
        region = str(entry["region"])
        try:
            bucket = str(
                self.factory("ssm", region).get_parameter(Name=self.data["artifactsBucketParameter"])["Parameter"][
                    "Value"
                ]
            )
        except (ClientError, BotoCoreError, KeyError) as exc:
            raise DeployError(
                f"cannot read the artifacts bucket name from SSM ({type(exc).__name__}): "
                "deploy the add-on artifacts bucket first"
            ) from exc
        try:
            self.factory("s3", region).head_bucket(Bucket=bucket)
        except (ClientError, BotoCoreError) as exc:
            raise DeployError(f"the artifacts bucket from SSM is not reachable ({type(exc).__name__})") from exc
        return bucket

    def verify_certificate(self, arn: str, domain: str) -> None:
        """The certificate must be ISSUED and issued for the environment host (us-east-1)."""
        try:
            certificate = self.factory("acm", "us-east-1").describe_certificate(CertificateArn=arn)["Certificate"]
        except (ClientError, BotoCoreError, KeyError) as exc:
            raise DeployError(f"cannot describe the certificate: {type(exc).__name__}") from exc
        if certificate.get("Status") != "ISSUED":
            raise DeployError(f"the certificate is {certificate.get('Status')}, expected ISSUED")
        if certificate.get("DomainName") != domain:
            raise DeployError("the certificate DomainName does not match the environment host")

    # -- SAM ----------------------------------------------------------------
    def run_sam(self, command: list[str]) -> None:
        full = [*command, *(["--profile", self.profile] if self.profile else [])]
        try:
            result = self.runner(full)
        except subprocess.TimeoutExpired as exc:
            raise DeployError(f"{' '.join(full[:2])} timed out after {int(exc.timeout or 0)} seconds") from exc
        if result.returncode != 0:
            raise DeployError(f"{' '.join(full[:2])} failed: {self.redact(result.stderr.strip())[:1500]}")

    def package_sam(self, entry: dict[str, Any], bucket: str) -> str:
        """sam build and sam package to the add-on bucket; returns the packaged template text."""
        unit = entry["unit"]
        build_dir = BUILD_DIR / "build" / unit
        packaged = build_dir / "packaged.yaml"
        common = ["--config-env", self.env, "--config-file", str(SAMCONFIG)]
        self.run_sam(
            [
                "sam",
                "build",
                "--template-file",
                str(REPO_ROOT / entry["template"]),
                "--build-dir",
                str(build_dir),
                *common,
            ]
        )
        prefix = str(self.data["artifactsPrefixPattern"]).format(repository=self.data["repository"], env=self.env)
        self.run_sam(
            [
                "sam",
                "package",
                "--template-file",
                str(build_dir / "template.yaml"),
                "--output-template-file",
                str(packaged),
                "--s3-bucket",
                bucket,
                "--s3-prefix",
                prefix,
                "--region",
                str(entry["region"]),
                *common,
            ]
        )
        text = self.files(packaged)
        found = re.search(r"CodeUri:\s*(s3://\S+)", text)
        if not found:
            raise DeployError("the packaged template has no S3 CodeUri")
        self.code_uri[unit] = found.group(1)
        return text

    def verify_code(self, entry: dict[str, Any]) -> None:
        """The deployed function CodeSha256 must equal the SHA-256 of the package that was uploaded."""
        bucket, _, key = self.code_uri[entry["unit"]].removeprefix("s3://").partition("/")
        region = str(entry["region"])
        try:
            body = self.factory("s3", region).get_object(Bucket=bucket, Key=key)["Body"].read()
            function = self.outputs(entry)["FunctionName"]
            deployed = self.factory("lambda", region).get_function_configuration(FunctionName=function)["CodeSha256"]
        except (ClientError, BotoCoreError, KeyError) as exc:
            raise DeployError(f"cannot verify the function code: {type(exc).__name__}") from exc
        expected = base64.b64encode(hashlib.sha256(body).digest()).decode()
        if deployed != expected:
            raise DeployError(f"CodeSha256 of {function} does not match the uploaded package")
        print(f"{entry['stack']}: CodeSha256 matches the uploaded package")

    # -- waits --------------------------------------------------------------
    def print_failed_events(self, entry: dict[str, Any]) -> None:
        try:
            events = self.cfn(entry).describe_stack_events(StackName=entry["stack"])["StackEvents"]
        except (ClientError, BotoCoreError, KeyError):
            return
        for event in events[:40]:
            if str(event.get("ResourceStatus", "")).endswith("_FAILED"):
                reason = self.redact(str(event.get("ResourceStatusReason", "")))
                print(f"  {event.get('LogicalResourceId')} {event['ResourceStatus']}: {reason}")

    def wait_stack(self, entry: dict[str, Any], expected: tuple[str, ...], timeout: float) -> None:
        start = self.monotonic()
        deadline = start + timeout
        deleting = "DELETE_COMPLETE" in expected
        while self.monotonic() < deadline:
            status = self.status(entry)
            if status is None and deleting:
                return
            if status is not None and not status.endswith("_IN_PROGRESS"):
                if status in expected:
                    return
                stale = deleting and status != "DELETE_FAILED" and self.monotonic() - start < DELETE_SETTLE_SECONDS
                if stale:
                    self.sleep(CHANGE_SET_POLL_SECONDS)
                    continue
                self.print_failed_events(entry)
                raise DeployError(f"stack {entry['stack']} ended in {status}")
            self.sleep(POLL_SECONDS)
        raise DeployError(f"timed out after {int(timeout // 60)} minutes waiting for stack {entry['stack']}")

    def describe_change_set(self, client: Any, stack: str, name: str) -> dict[str, Any]:
        """The change set with every page of Changes (NextToken followed)."""
        changes: list[dict[str, Any]] = []
        token: str | None = None
        while True:
            args: dict[str, Any] = {"StackName": stack, "ChangeSetName": name}
            if token:
                args["NextToken"] = token
            page = client.describe_change_set(**args)
            changes.extend(page.get("Changes", []))
            token = page.get("NextToken")
            if not token:
                return {**page, "Changes": changes}

    def wait_change_set(self, entry: dict[str, Any], name: str) -> dict[str, Any] | None:
        """The finished change set; None when it holds no changes."""
        client, stack = self.cfn(entry), entry["stack"]
        deadline = self.monotonic() + CHANGE_SET_TIMEOUT_SECONDS
        while self.monotonic() < deadline:
            try:
                page = self.describe_change_set(client, stack, name)
            except (ClientError, BotoCoreError) as exc:
                raise DeployError(f"cannot read the change set of {stack}: {type(exc).__name__}") from exc
            status = page.get("Status")
            if status == "CREATE_COMPLETE":
                return page
            if status == "FAILED":
                reason = str(page.get("StatusReason", ""))
                if any(marker in reason for marker in NO_CHANGES_MARKERS):
                    return None
                raise DeployError(f"change set of {stack} failed: {self.redact(reason)}")
            self.sleep(CHANGE_SET_POLL_SECONDS)
        raise DeployError(f"timed out waiting for the change set of {stack}")

    def wait_execution(self, entry: dict[str, Any], ref: str, timeout: float, kind: str = "UPDATE") -> None:
        """Wait until the change set reports that its execution finished.

        `ref` is the change set Id (ARN): CloudFormation can drop the change set of a CREATE once its
        execution starts, and then the name no longer resolves. If the change set is gone anyway, a CREATE
        whose stack is already in a CREATE_IN_PROGRESS/CREATE_COMPLETE state moves on to the stack wait;
        anything else fails closed.

        The status of the stack can still show the state before the execution for a moment, so the
        execution status of the change set is the signal; the stack status is checked afterwards.
        """
        client, stack = self.cfn(entry), entry["stack"]
        deadline = self.monotonic() + timeout
        while self.monotonic() < deadline:
            try:
                state = str(client.describe_change_set(ChangeSetName=ref).get("ExecutionStatus"))
            except (ClientError, BotoCoreError) as exc:
                gone = kind == "CREATE" and error_label(exc) == "ChangeSetNotFoundException"
                if gone and self.status(entry) in ("CREATE_IN_PROGRESS", "CREATE_COMPLETE"):
                    return
                raise DeployError(f"cannot read the execution of {stack}: {type(exc).__name__}") from exc
            if state == "EXECUTE_COMPLETE":
                return
            if state not in ("EXECUTE_IN_PROGRESS", "AVAILABLE"):
                self.print_failed_events(entry)
                raise DeployError(f"stack {entry['stack']} ended in {state}")
            self.sleep(POLL_SECONDS)
        raise DeployError(f"timed out after {int(timeout // 60)} minutes waiting for stack {stack}")

    def discard_change_set(self, entry: dict[str, Any], name: str) -> None:
        """Delete the change set, and the empty REVIEW_IN_PROGRESS shell a refused CREATE leaves behind."""
        client = self.cfn(entry)
        try:
            client.delete_change_set(StackName=entry["stack"], ChangeSetName=name)
            if self.status(entry) == "REVIEW_IN_PROGRESS":
                client.delete_stack(StackName=entry["stack"])
        except (ClientError, BotoCoreError) as exc:
            raise DeployError(f"cannot delete the change set {name}: {type(exc).__name__}") from exc

    def delete_stack(self, entry: dict[str, Any]) -> None:
        try:
            self.cfn(entry).delete_stack(StackName=entry["stack"])
        except (ClientError, BotoCoreError) as exc:
            raise DeployError(f"cannot delete stack {entry['stack']}: {error_label(exc)}") from exc
        self.wait_stack(entry, ("DELETE_COMPLETE",), STACK_TIMEOUT_SECONDS)

    # -- deploy -------------------------------------------------------------
    def check_status(self, entry: dict[str, Any], status: str | None, recover: bool) -> str | None:
        if status in (None, "REVIEW_IN_PROGRESS") or status in OK_TO_DEPLOY:
            return status
        if recover and status == "ROLLBACK_COMPLETE":
            print(f"{entry['stack']}: ROLLBACK_COMPLETE, deleting this stack to create it again (dev)")
            self.delete_stack(entry)
            return None
        raise DeployError(f"stack {entry['stack']} is in {status}: investigate it (read-only) before deploying again")

    def drift_report(self, entry: dict[str, Any]) -> None:
        """Read-only drift report of an existing prod stack. Problems are reported, not fatal."""
        client, stack = self.cfn(entry), entry["stack"]
        try:
            detection = client.detect_stack_drift(StackName=stack)["StackDriftDetectionId"]
            deadline = self.monotonic() + DRIFT_TIMEOUT_SECONDS
            while self.monotonic() < deadline:
                state = client.describe_stack_drift_detection_status(StackDriftDetectionId=detection)
                if state["DetectionStatus"] != "DETECTION_IN_PROGRESS":
                    break
                self.sleep(POLL_SECONDS)
            else:
                print(f"{stack}: drift detection timed out (report skipped)")
                return
            drifts = client.describe_stack_resource_drifts(
                StackName=stack, StackResourceDriftStatusFilters=["MODIFIED", "DELETED"]
            )["StackResourceDrifts"]
        except (ClientError, BotoCoreError, KeyError) as exc:
            print(f"{stack}: drift report unavailable ({type(exc).__name__})")
            return
        print(f"{stack}: drift report, {len(drifts)} resources drifted")
        for drift in drifts:
            print(
                f"  {drift.get('LogicalResourceId')} {drift.get('ResourceType')}"
                f" {drift.get('StackResourceDriftStatus')}"
            )

    def harden_prod(self, entry: dict[str, Any], policy: dict[str, Any]) -> None:
        client, stack = self.cfn(entry), entry["stack"]
        try:
            client.update_termination_protection(StackName=stack, EnableTerminationProtection=True)
            client.set_stack_policy(StackName=stack, StackPolicyBody=json.dumps(policy))
        except (ClientError, BotoCoreError) as exc:
            raise DeployError(f"cannot protect {stack}: {type(exc).__name__}") from exc
        print(f"{stack}: termination protection on, stack policy attached")

    def deploy_stack(
        self,
        entry: dict[str, Any],
        config: dict[str, Any],
        bucket: str | None,
        recover: bool,
        review_only: bool = False,
    ) -> None:
        stack, unit = entry["stack"], entry["unit"]
        print(f"::group::{stack}")
        status = self.check_status(entry, self.status(entry), recover)
        if self.env == "prod" and status in OK_TO_DEPLOY:
            self.drift_report(entry)
        body = self.package_sam(entry, bucket) if entry["sam"] and bucket else None
        if body is None:
            body = self.files(REPO_ROOT / entry["template"])
        if len(body.encode("utf-8")) > TEMPLATE_BODY_LIMIT:
            raise DeployError(f"{entry['template']} is larger than {TEMPLATE_BODY_LIMIT} bytes")
        parameters = self.stack_parameters(entry, config, review_only)
        values = {p["ParameterKey"]: p["ParameterValue"] for p in parameters}
        if unit == "frontend" and values["CertificateArn"] != REVIEW_PLACEHOLDER:
            self.verify_certificate(values["CertificateArn"], str(config["Parameters"]["DomainName"]))
        run_id = self.environ.get("GITHUB_RUN_ID", str(int(time.time())))
        attempt = self.environ.get("GITHUB_RUN_ATTEMPT", "1")
        name = re.sub(r"[^A-Za-z0-9-]", "-", f"iac-{run_id}-{attempt}-{unit}")[:128]
        kind = "CREATE" if status in (None, "REVIEW_IN_PROGRESS") else "UPDATE"
        try:
            created = self.cfn(entry).create_change_set(
                StackName=stack,
                ChangeSetName=name,
                ChangeSetType=kind,
                TemplateBody=body,
                Parameters=parameters,
                Tags=[{"Key": k, "Value": str(v)} for k, v in config["Tags"].items()],
                Capabilities=CAPABILITIES,
            )
        except (ClientError, BotoCoreError) as exc:
            raise DeployError(f"cannot create the change set of {stack}: {self.redact(str(exc))[:500]}") from exc
        try:
            page = self.wait_change_set(entry, name)
        except DeployError:
            if review_only:
                self.discard_change_set(entry, name)
            raise
        if page is None:
            self.discard_change_set(entry, name)
            print(f"{stack}: no changes")
        elif review_only:
            self.guard_change_set(entry, name, page)
            self.discard_change_set(entry, name)
            print(f"{stack}: reviewed, change set deleted, nothing executed")
        else:
            self.execute_if_safe(entry, name, page, kind, str(created.get("Id") or name))
        if not review_only:
            if self.env == "prod":
                self.harden_prod(entry, load_stack_policy())
            if entry["sam"]:
                self.verify_code(entry)
        print("::endgroup::")

    def guard_change_set(self, entry: dict[str, Any], name: str, page: dict[str, Any]) -> None:
        """Print the changes and apply the guard; a refused change set is printed in full and deleted."""
        stack = entry["stack"]
        for change in page["Changes"]:
            detail = change.get("ResourceChange", {})
            print(
                f"  {str(detail.get('Action')):<7} {str(detail.get('ResourceType')):<45}"
                f" {detail.get('LogicalResourceId')} replacement={detail.get('Replacement', '-')}"
            )
        violations = guard_changes(page["Changes"])
        if violations:
            print(f"Change set {name} of {stack} in full:")
            print(self.redact(json.dumps(page["Changes"], indent=2, default=str)))
            for violation in violations:
                print(f"::error::Change set guard: {stack}: {violation}")
            self.discard_change_set(entry, name)
            raise DeployError(f"the change set guard refused {stack}; the change set was deleted")

    def execute_if_safe(self, entry: dict[str, Any], name: str, page: dict[str, Any], kind: str, ref: str) -> None:
        stack = entry["stack"]
        self.guard_change_set(entry, name, page)
        try:
            self.cfn(entry).execute_change_set(ChangeSetName=ref)
        except (ClientError, BotoCoreError) as exc:
            raise DeployError(f"cannot execute the change set of {stack}: {type(exc).__name__}") from exc
        timeout = CERT_TIMEOUT_SECONDS if entry["unit"] == "cert" else STACK_TIMEOUT_SECONDS
        self.wait_execution(entry, ref, timeout, kind)
        self.wait_stack(entry, ("CREATE_COMPLETE", "UPDATE_COMPLETE"), timeout)
        print(f"{stack}: {kind.lower()} complete")

    def deploy(self, recover: bool = False, review_only: bool = False) -> None:
        if recover and self.env != "dev":
            raise DeployError("--recover-rollback is only allowed in dev")
        if recover and review_only:
            raise DeployError("--recover-rollback cannot be combined with --review-only")
        if self.parameters_env != self.env and not review_only:
            raise DeployError(f"--parameters-env {self.parameters_env} with --env {self.env} needs --review-only")
        config = self.load_parameters()
        self.check_variables()
        self.check_hosted_zone(config)
        sam_entries = [e for e in self.entries if e["sam"]]
        bucket = self.artifacts_bucket(sam_entries[0]) if sam_entries else None
        for entry in self.entries:
            self.deploy_stack(entry, config, bucket, recover, review_only)
        if review_only:
            print("Review only: nothing was executed, all change sets were deleted.")
        else:
            self.print_summary()

    def print_summary(self) -> None:
        auth = self.outputs(self.entry_of("auth"))
        print("Deploy summary (identifiers only, no secret values):")
        print(f"COGNITO_USER_POOL_ID={auth['UserPoolId']}")
        print(f"COGNITO_APP_CLIENT_ID={auth['AppClientId']}")

    # -- destroy (dev only) -------------------------------------------------
    def empty_bucket(self, bucket: str) -> int:
        """Delete every object version and delete marker of the web bucket (dev only)."""
        if self.env != "dev":
            raise DeployError("buckets are emptied only in dev")
        s3 = self.factory("s3", str(self.entry_of("frontend")["region"]))
        removed = 0
        while True:
            try:
                page = s3.list_object_versions(Bucket=bucket, MaxKeys=1000)
            except ClientError as exc:
                if error_code(exc) == "NoSuchBucket":
                    return removed
                raise DeployError(f"cannot empty the web bucket: {error_code(exc)}") from exc
            objects = [
                {"Key": item["Key"], "VersionId": item["VersionId"]}
                for kind in ("Versions", "DeleteMarkers")
                for item in page.get(kind) or []
            ]
            if not objects:
                return removed
            result = s3.delete_objects(Bucket=bucket, Delete={"Objects": objects, "Quiet": True})
            errors = result.get("Errors") or []
            if errors:
                sample = "; ".join(f"{e.get('Key')}: {e.get('Code')}" for e in errors[:5])
                raise DeployError(f"cannot empty the web bucket: {len(errors)} objects not deleted ({sample})")
            removed += len(objects)

    def user_count(self, auth: dict[str, Any]) -> str:
        try:
            pool = self.outputs(auth)["UserPoolId"]
            users = self.factory("cognito-idp", str(auth["region"])).describe_user_pool(UserPoolId=pool)["UserPool"][
                "EstimatedNumberOfUsers"
            ]
        except (DeployError, ClientError, BotoCoreError, KeyError):
            return "unknown"
        return str(users)

    def secret_name(self) -> str:
        parameters = self.load_parameters()["Parameters"]
        return f"sm-{parameters['RegionCode']}-{parameters['Context']}-auth-app-client-{self.env}"

    def force_delete_secret(self) -> None:
        """A secret left pending deletion keeps its name for days: delete it now so it can be recreated."""
        region = str(self.entry_of("auth")["region"])
        client = self.factory("secretsmanager", region)
        name = self.secret_name()
        try:
            secret = client.describe_secret(SecretId=name)
            if secret.get("DeletedDate"):
                client.delete_secret(SecretId=name, ForceDeleteWithoutRecovery=True)
                print("The client secret was pending deletion: deleted now, without recovery (dev)")
            else:
                print("The client secret is still active; the leftover check will report it")
        except ClientError as exc:
            if error_code(exc) != "ResourceNotFoundException":
                raise DeployError(f"cannot handle the client secret: {error_code(exc)}") from exc

    def destroy_stack(self, entry: dict[str, Any]) -> None:
        stack, client = entry["stack"], self.cfn(entry)
        print(f"::group::Delete {stack}")
        described = self.describe(entry)
        try:
            if described and described.get("EnableTerminationProtection"):
                client.update_termination_protection(StackName=stack, EnableTerminationProtection=False)
                print("Termination protection turned off (dev)")
            resources = client.list_stack_resources(StackName=stack)["StackResourceSummaries"]
        except (ClientError, BotoCoreError, KeyError) as exc:
            raise DeployError(f"cannot prepare the deletion of {stack}: {error_label(exc)}") from exc
        for item in resources:
            physical = item.get("PhysicalResourceId")
            if item["ResourceType"] == "AWS::S3::Bucket" and physical:
                print(f"Emptied a web bucket: {self.empty_bucket(physical)} versions removed")
        self.delete_stack(entry)
        print(f"{stack}: deleted")
        print("::endgroup::")

    def destroy(self, mode: str) -> None:
        if self.env != "dev":
            raise DeployError("destroy is only supported for dev")
        self.load_parameters()
        present = [(entry, status) for entry in reversed(self.entries) if (status := self.status(entry)) is not None]
        for entry, status in present:
            if status.endswith("_IN_PROGRESS"):
                raise DeployError(f"stack {entry['stack']} is {status}: wait for it before destroying")
        print(f"Destroy DEV with CloudFormation: {len(present)} stacks present (reverse deploy order)")
        for entry, status in present:
            print(f"- {entry['stack']} ({status})")
        auth = self.entry_of("auth")
        if any(entry is auth for entry, _ in present):
            print(f"Cognito users in the pool: {self.user_count(auth)} (all are deleted with the pool)")
        if mode != "destroy":
            print("Nothing was deleted (mode plan).")
            return
        for entry, _ in present:
            self.destroy_stack(entry)
        self.force_delete_secret()


def command_deploy(deployer: Deployer, args: argparse.Namespace) -> int:
    deployer.deploy(recover=args.recover_rollback, review_only=args.review_only)
    return 0


def command_destroy(deployer: Deployer, args: argparse.Namespace) -> int:
    deployer.destroy(args.mode)
    return 0


def command_output(deployer: Deployer, args: argparse.Namespace) -> int:
    print(deployer.output_of(args.unit, args.key))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="CloudFormation deploy and destroy driver")
    sub = parser.add_subparsers(dest="command", required=True)
    deploy = sub.add_parser("deploy")
    deploy.add_argument("--env", required=True, choices=ENVIRONMENTS)
    deploy.add_argument("--recover-rollback", action="store_true")
    deploy.add_argument("--review-only", action="store_true")
    deploy.add_argument("--parameters-env", choices=ENVIRONMENTS, default=None)
    deploy.set_defaults(handler=command_deploy)
    destroy = sub.add_parser("destroy")
    destroy.add_argument("--env", required=True, choices=["dev"])
    destroy.add_argument("--mode", required=True, choices=["plan", "destroy"])
    destroy.set_defaults(handler=command_destroy)
    output = sub.add_parser("output")
    output.add_argument("--env", required=True, choices=ENVIRONMENTS)
    output.add_argument("--unit", required=True)
    output.add_argument("--key", required=True)
    output.set_defaults(handler=command_output)
    for command in (deploy, destroy, output):
        command.add_argument("--profile", default=None, help="AWS profile (local runs only)")
    return parser


def main(
    argv: list[str] | None = None,
    factory: ClientFactory | None = None,
    runner: Runner = default_runner,
    environ: Mapping[str, str] | None = None,
    files: FileReader = read_utf8,
    sleep: Callable[[float], None] = time.sleep,
    monotonic: Callable[[], float] = time.monotonic,
) -> int:
    args = build_parser().parse_args(argv)
    hidden = hidden_values(os.environ if environ is None else environ)
    try:
        deployer = Deployer(
            env=args.env,
            factory=factory or make_client_factory(args.profile),
            runner=runner,
            environ=environ,
            files=files,
            sleep=sleep,
            monotonic=monotonic,
            profile=args.profile,
            parameters_env=getattr(args, "parameters_env", None),
        )
        return int(args.handler(deployer, args))
    except DeployError as exc:
        print(f"::error::{mask(str(exc), hidden)}")
        return 1
    except BotoCoreError as exc:
        print(f"::error::AWS configuration error: {type(exc).__name__}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
