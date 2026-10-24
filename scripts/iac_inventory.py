"""Read-only inventory of the CloudFormation stacks of one environment, without values.

For every stack of templates/stacks.json it lists status, termination protection, whether a stack policy
is attached, the output keys and the resources (logical ID, type, status). Physical IDs, output values and
parameters are never included, so the result can go into the closing documentation or a post-deploy report.

    python scripts/iac_inventory.py --env dev|prod [--format json|markdown] [--output FILE] [--profile P]

Without --output the result goes to stdout. Exit codes: 0 done; 1 a stack could not be read (fail closed);
2 bad arguments. Only describe and list calls are made.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from botocore.exceptions import BotoCoreError, ClientError

from iac_common import (
    ENVIRONMENTS,
    ClientFactory,
    ConfigError,
    error_code,
    is_missing_stack,
    load_stacks,
    make_client_factory,
)


class InventoryError(Exception):
    """A stack could not be read."""


def stack_resources(client: Any, stack: str) -> list[dict[str, str]]:
    resources: list[dict[str, str]] = []
    token: str | None = None
    while True:
        page = client.list_stack_resources(StackName=stack, **({"NextToken": token} if token else {}))
        resources.extend(
            {
                "logicalId": item["LogicalResourceId"],
                "type": item["ResourceType"],
                "status": item["ResourceStatus"],
            }
            for item in page["StackResourceSummaries"]
        )
        token = page.get("NextToken")
        if not token:
            return sorted(resources, key=lambda r: r["logicalId"])


def describe_entry(entry: dict[str, Any], factory: ClientFactory) -> dict[str, Any]:
    client = factory("cloudformation", str(entry["region"]))
    base: dict[str, Any] = {
        "unit": entry["unit"],
        "stack": entry["stack"],
        "region": entry["region"],
    }
    try:
        stack = client.describe_stacks(StackName=entry["stack"])["Stacks"][0]
        policy = client.get_stack_policy(StackName=entry["stack"])
        resources = stack_resources(client, entry["stack"])
    except ClientError as exc:
        if is_missing_stack(exc):
            return {
                **base,
                "status": "ABSENT",
                "terminationProtection": False,
                "stackPolicy": False,
                "outputKeys": [],
                "resources": [],
            }
        raise InventoryError(f"cannot read stack {entry['stack']}: {error_code(exc)}") from exc
    except (BotoCoreError, KeyError, IndexError) as exc:
        raise InventoryError(f"cannot read stack {entry['stack']}: {type(exc).__name__}") from exc
    return {
        **base,
        "status": stack["StackStatus"],
        "terminationProtection": bool(stack.get("EnableTerminationProtection")),
        "stackPolicy": bool(policy.get("StackPolicyBody")),
        "outputKeys": sorted(o["OutputKey"] for o in stack.get("Outputs", [])),
        "resources": resources,
    }


def build_inventory(env: str, factory: ClientFactory) -> dict[str, Any]:
    _, entries = load_stacks(env)
    return {"environment": env, "stacks": [describe_entry(entry, factory) for entry in entries]}


def render_markdown(inventory: dict[str, Any]) -> str:
    lines = [f"## Stack inventory: {inventory['environment']}", ""]
    for stack in inventory["stacks"]:
        lines.append(f"### {stack['stack']} ({stack['region']})")
        lines.append(
            f"Status {stack['status']}, termination protection {stack['terminationProtection']},"
            f" stack policy {stack['stackPolicy']}, outputs: {', '.join(stack['outputKeys']) or 'none'}"
        )
        lines.append("")
        if stack["resources"]:
            lines.extend(["| Logical ID | Type | Status |", "|---|---|---|"])
            lines.extend(f"| {r['logicalId']} | {r['type']} | {r['status']} |" for r in stack["resources"])
            lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None, client_factory: ClientFactory | None = None) -> int:
    parser = argparse.ArgumentParser(description="Inventory of the stacks of one environment")
    parser.add_argument("--env", required=True, choices=ENVIRONMENTS)
    parser.add_argument("--format", choices=["json", "markdown"], default="json")
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--profile", default=None, help="AWS profile (local runs only)")
    args = parser.parse_args(argv)
    try:
        inventory = build_inventory(args.env, client_factory or make_client_factory(args.profile))
    except (InventoryError, ConfigError) as exc:
        print(f"::error::{exc}")
        return 1
    text = (json.dumps(inventory, indent=2) if args.format == "json" else render_markdown(inventory)) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8", newline="\n")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
