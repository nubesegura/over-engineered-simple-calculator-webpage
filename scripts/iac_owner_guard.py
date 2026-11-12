"""Owner guard: one IaC tool per environment, fail closed.

The same infrastructure can be deployed with Terraform (Terragrunt) or with CloudFormation (SAM) under the
same resource names, so the two tools must never manage one environment at the same time. The owner is
detected from what exists (no marker tag):

* CloudFormation owns it when any stack of templates/stacks.json for the environment exists, in either
  Region, in any status except DELETE_COMPLETE (ROLLBACK_COMPLETE, REVIEW_IN_PROGRESS, DELETE_FAILED and
  every *_IN_PROGRESS count as present).
* Terraform owns it when the state object of any Terragrunt unit exists and holds at least one managed
  resource. The state is streamed into memory only to count resources; it is never written to disk or printed.
  A missing object or bucket (NoSuchKey, NoSuchBucket) counts as no state.

Any other answer (AccessDenied, throttling, a network error, a malformed response, an oversized state)
stops the guard: it never guesses.

Command line (read-only; credentials come from the environment or --profile):

    python scripts/iac_owner_guard.py check --env dev|prod [--tool terraform|cloudformation]
    python scripts/iac_owner_guard.py detect --env dev|prod

check   Run before any plan or deploy. The tool is --tool, else the IAC_TOOL environment variable; unset or
        empty means cloudformation; any other value is refused. Exit codes:
        0 the environment is free or already owned by the tool
        2 it is owned by the other tool
        3 both tools own resources (inconsistent, fix by hand)
        4 ownership could not be determined, or bad arguments (including an invalid tool)
detect  For the destroy workflow, which removes what exists with the tool that created it. Prints
        owner=terraform|cloudformation|none|both as a line on stdout (details go to stderr). Exit codes:
        0 terraform, cloudformation or none   3 both   4 not determined (nothing printed on stdout)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any, NoReturn, TextIO

from botocore.exceptions import BotoCoreError, ClientError

from iac_common import (
    ENVIRONMENTS,
    STACKS_FILE,
    ClientFactory,
    ConfigError,
    error_code,
    is_missing_stack,
    load_stacks,
    make_client_factory,
)

TOOLS = ("terraform", "cloudformation")
DEFAULT_TOOL = "cloudformation"
MAX_STATE_BYTES = 64 * 1024 * 1024

EXIT_ALLOWED = 0
EXIT_OTHER_TOOL = 2
EXIT_BOTH_TOOLS = 3
EXIT_UNREADABLE = 4

MISSING_STATE_CODES = frozenset({"NoSuchKey", "NoSuchBucket", "404"})


class GuardError(Exception):
    """Ownership cannot be determined; the guard fails closed."""


class _ArgumentParser(argparse.ArgumentParser):
    """Argument errors also fail closed, with the 'unreadable' exit code."""

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        print(f"iac_owner_guard: error: {message}", file=sys.stderr)
        raise SystemExit(EXIT_UNREADABLE)


def resolve_tool(value: str | None) -> str:
    """Unset or empty means cloudformation; anything but the two known tools is refused."""
    tool = (value or "").strip() or DEFAULT_TOOL
    if tool not in TOOLS:
        raise GuardError(f"IAC_TOOL must be 'terraform' or 'cloudformation' (or unset), got '{tool}'")
    return tool


def cloudformation_stacks_present(entries: list[dict[str, Any]], factory: ClientFactory) -> list[tuple[str, str]]:
    """(stack name, status) of every stack of the environment that exists, in its own Region."""
    present: list[tuple[str, str]] = []
    for entry in entries:
        stack = str(entry["stack"])
        client = factory("cloudformation", str(entry["region"]))
        try:
            answer = client.describe_stacks(StackName=stack)
        except ClientError as exc:
            if is_missing_stack(exc):
                continue
            raise GuardError(f"cannot describe stack {stack}: {error_code(exc)}") from exc
        except BotoCoreError as exc:
            raise GuardError(f"cannot describe stack {stack}: {type(exc).__name__}") from exc
        stacks = answer.get("Stacks") if isinstance(answer, dict) else None
        if not isinstance(stacks, list) or not stacks:
            raise GuardError(f"malformed describe-stacks response for {stack}")
        for item in stacks:
            status = item.get("StackStatus") if isinstance(item, dict) else None
            if not isinstance(status, str):
                raise GuardError(f"malformed describe-stacks response for {stack}")
            if status != "DELETE_COMPLETE":
                present.append((stack, status))
    return present


def _account_id(factory: ClientFactory, region: str) -> str:
    try:
        account = factory("sts", region).get_caller_identity().get("Account")
    except (ClientError, BotoCoreError) as exc:
        raise GuardError("cannot read the caller account (sts get-caller-identity)") from exc
    if not (isinstance(account, str) and account.isdigit() and len(account) == 12):
        raise GuardError("malformed caller identity")
    return account


def _count_managed(state_text: str) -> int:
    resources = json.loads(state_text)["resources"]
    if not isinstance(resources, list):
        raise ValueError("resources is not a list")
    return sum(len(resource.get("instances", [])) for resource in resources if resource.get("mode") == "managed")


def terraform_units_with_resources(data: Mapping[str, Any], env: str, factory: ClientFactory) -> list[tuple[str, int]]:
    """(unit, managed resource count) of every unit whose state holds resources. Nothing is written."""
    region = str(data["terraformStateRegion"])
    bucket = str(data["terraformStateBucketPattern"]).format(
        region_code=region.replace("-", ""), env=env, account_id=_account_id(factory, region)
    )
    s3 = factory("s3", region)
    owned: list[tuple[str, int]] = []
    for unit in data["terraformUnits"]:
        key = str(data["terraformStateKeyPattern"]).format(repository=data["repository"], env=env, unit=unit)
        try:
            body = s3.get_object(Bucket=bucket, Key=key)["Body"].read(MAX_STATE_BYTES + 1)
        except ClientError as exc:
            if error_code(exc) in MISSING_STATE_CODES:
                continue
            raise GuardError(f"cannot read the state object of unit {unit}: {error_code(exc)}") from exc
        except BotoCoreError as exc:
            raise GuardError(f"cannot read the state object of unit {unit}") from exc
        if len(body) > MAX_STATE_BYTES:
            raise GuardError(f"the state object of unit {unit} is larger than expected")
        try:
            count = _count_managed(body.decode("utf-8"))
        except (ValueError, KeyError, TypeError, AttributeError) as exc:
            raise GuardError(f"malformed state object for unit {unit}") from exc
        if count > 0:
            owned.append((unit, count))
    return owned


def decide(tool: str, env: str, cfn_present: bool, tf_present: bool) -> tuple[int, str]:
    """Map the detected owner to an exit code and a message."""
    if cfn_present and tf_present:
        return (
            EXIT_BOTH_TOOLS,
            f"The {env} environment has resources from both Terraform and CloudFormation: "
            "inconsistent state, fix it by hand before any deployment.",
        )
    owner = "cloudformation" if cfn_present else "terraform" if tf_present else "none"
    if owner in ("none", tool):
        return EXIT_ALLOWED, f"Owner of {env}: {owner}. Requested tool: {tool}. Allowed."
    message = (
        f"The {env} environment is deployed with {owner}. Destroy it with that tool "
        f"(Destroy DEV detects the owner and uses {owner}) before switching to {tool}."
    )
    if env == "prod":
        message += " Switching prod needs the planned destroy and recreate, with its own authorization."
    return EXIT_OTHER_TOOL, message


def detect_owner(stacks: list[tuple[str, str]], units: list[tuple[str, int]]) -> str:
    if stacks and units:
        return "both"
    return "cloudformation" if stacks else "terraform" if units else "none"


def _inspect(
    env: str, stacks_file: Path, factory: ClientFactory
) -> tuple[list[tuple[str, str]], list[tuple[str, int]]]:
    try:
        data, entries = load_stacks(env, stacks_file)
        return (
            cloudformation_stacks_present(entries, factory),
            terraform_units_with_resources(data, env, factory),
        )
    except (ConfigError, KeyError, TypeError) as exc:
        raise GuardError(f"cannot read {stacks_file.name}: {exc}") from exc


def _report(env: str, stacks: list[tuple[str, str]], units: list[tuple[str, int]], stream: TextIO) -> None:
    print(f"CloudFormation stacks present in {env}: {len(stacks)}", file=stream)
    for name, status in stacks:
        print(f"  {name} ({status})", file=stream)
    print(f"Terraform units with resources in {env}: {len(units)}", file=stream)
    for unit, count in units:
        print(f"  {unit}: {count} resources", file=stream)


def command_check(args: argparse.Namespace, factory: ClientFactory, environ: Mapping[str, str]) -> int:
    try:
        tool = resolve_tool(args.tool if args.tool is not None else environ.get("IAC_TOOL"))
    except GuardError as exc:
        print(f"::error::{exc}")
        return EXIT_UNREADABLE
    try:
        stacks, units = _inspect(args.env, args.stacks_file, factory)
    except GuardError as exc:
        print(f"::error::Owner guard cannot determine the owner of {args.env}: {exc}. Failing closed.")
        return EXIT_UNREADABLE
    _report(args.env, stacks, units, sys.stdout)
    code, message = decide(tool, args.env, bool(stacks), bool(units))
    print(message if code == EXIT_ALLOWED else f"::error::{message}")
    return code


def command_detect(args: argparse.Namespace, factory: ClientFactory, environ: Mapping[str, str]) -> int:
    del environ
    try:
        stacks, units = _inspect(args.env, args.stacks_file, factory)
    except GuardError as exc:
        print(
            f"::error::Owner guard cannot determine the owner of {args.env}: {exc}. Failing closed.",
            file=sys.stderr,
        )
        return EXIT_UNREADABLE
    _report(args.env, stacks, units, sys.stderr)
    owner = detect_owner(stacks, units)
    print(f"owner={owner}")
    if owner == "both":
        print(
            f"::error::The {args.env} environment has resources from both Terraform and "
            "CloudFormation: inconsistent state, fix it by hand.",
            file=sys.stderr,
        )
        return EXIT_BOTH_TOOLS
    return EXIT_ALLOWED


def build_parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(description="One IaC tool per environment (fail closed)")
    sub = parser.add_subparsers(dest="command", required=True, parser_class=_ArgumentParser)
    check = sub.add_parser("check", help="free or owned by the tool passes")
    check.add_argument("--tool", default=None, help="default: the IAC_TOOL environment variable")
    detect = sub.add_parser("detect", help="print owner=terraform|cloudformation|none|both")
    for command in (check, detect):
        command.add_argument("--env", required=True, choices=ENVIRONMENTS)
        command.add_argument("--stacks-file", type=Path, default=STACKS_FILE)
        command.add_argument("--profile", default=None, help="AWS profile (local runs only)")
    check.set_defaults(handler=command_check)
    detect.set_defaults(handler=command_detect)
    return parser


def main(
    argv: list[str] | None = None,
    client_factory: ClientFactory | None = None,
    environ: Mapping[str, str] | None = None,
) -> int:
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else EXIT_UNREADABLE
    if environ is None:
        environ = os.environ
    try:
        factory = client_factory or make_client_factory(args.profile)
    except BotoCoreError as exc:
        print(f"::error::Owner guard cannot create the AWS clients ({type(exc).__name__}). Failing closed.")
        return EXIT_UNREADABLE
    return int(args.handler(args, factory, environ))


if __name__ == "__main__":
    sys.exit(main())
