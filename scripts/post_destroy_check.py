#!/usr/bin/env python3
"""Read-only check that nothing of a repository is left in an environment after a destroy.

1. Resource Groups Tagging API: every resource tagged repo-name=<repository> (and env-type=<env>).
2. Kinds the tagging API does not return or that carry no tags: EventBridge Scheduler schedules, active ECS task
   definition families, IAM roles by naming convention, secrets (also those scheduled for deletion), KMS keys
   (also pending deletion) and log groups by naming convention.
3. Known and expected residues are labelled, not hidden: KMS keys pending deletion, secrets scheduled for deletion.

4. The CloudFormation path adds Secrets Manager secrets, SNS topics, CloudWatch alarms and log groups in
   both Regions of the stacks (us-east-2 and us-east-1), found by naming convention and filtered by the
   repo-name tag. A secret scheduled for deletion is an expected residue unless --strict-secrets is given
   (the CloudFormation destroy force-deletes it, because a pending secret keeps its name).
5. CloudFront origin access controls (oac-*) and custom response headers policies (rhp-*) of the project, found by
   naming convention (they carry no tags); read once because CloudFront is global.

Usage: python scripts/post_destroy_check.py --repo-name <repository> --env dev [--profile P]
           [--region us-east-2 --region us-east-1] [--context oecalc] [--strict-secrets]
Exit code 0 when nothing unexpected is left, 1 otherwise, 2 when a read fails. Only list and describe calls are made.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from collections.abc import Callable
from typing import Any


def aws(args: list[str], profile: str | None, region: str) -> dict[str, Any]:
    cmd = ["aws", *args, "--region", region, "--output", "json"] + (["--profile", profile] if profile else [])
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"aws {' '.join(args[:2])} failed: {re.sub(r'[0-9]{12}', '************', result.stderr.strip())[:200]}"
        )
    return json.loads(result.stdout) if result.stdout.strip() else {}


DEFAULT_REGIONS = ("us-east-2", "us-east-1")
_CACHE: dict[str, set[str]] = {}


def is_stale(arn: str, profile: str | None, region: str) -> bool:
    """True when the tagging index still lists a resource that no longer exists or is only a tombstone.

    The tagging API lags behind deletes; ECS keeps INACTIVE clusters, services and task definitions and
    STOPPED tasks visible for a while; NAT gateways stay 'deleted' for about an hour. Unknown types are never stale.
    """
    svc, rest = arn.split(":")[2], arn.split(":", 5)[5]
    try:
        if svc == "ecs":
            kind, _, name = rest.partition("/")
            if kind == "task-definition":
                if "active_td" not in _CACHE:
                    _CACHE["active_td"] = set(
                        aws(
                            ["ecs", "list-task-definitions", "--status", "ACTIVE"],
                            profile,
                            region,
                        ).get("taskDefinitionArns", [])
                    )
                return arn not in _CACHE["active_td"]
            cluster = name.split("/")[0]
            if kind == "cluster":
                found = aws(["ecs", "describe-clusters", "--clusters", arn], profile, region).get("clusters", [])
                return not found or found[0]["status"] == "INACTIVE"
            if kind == "service":
                found = aws(
                    [
                        "ecs",
                        "describe-services",
                        "--cluster",
                        cluster,
                        "--services",
                        arn,
                    ],
                    profile,
                    region,
                ).get("services", [])
                return not found or found[0]["status"] == "INACTIVE"
            if kind == "task":
                found = aws(
                    ["ecs", "describe-tasks", "--cluster", cluster, "--tasks", arn],
                    profile,
                    region,
                ).get("tasks", [])
                return not found or found[0]["lastStatus"] == "STOPPED"
        if svc == "ec2":
            kind, _, rid = rest.partition("/")
            if kind == "natgateway":
                found = aws(
                    ["ec2", "describe-nat-gateways", "--nat-gateway-ids", rid],
                    profile,
                    region,
                ).get("NatGateways", [])
                return not found or found[0]["State"] == "deleted"
            if kind == "vpc-endpoint":
                found = aws(
                    ["ec2", "describe-vpc-endpoints", "--vpc-endpoint-ids", rid],
                    profile,
                    region,
                ).get("VpcEndpoints", [])
                return not found or found[0]["State"] in ("deleted", "deleting")
            by_id = {
                "security-group": (
                    "describe-security-groups",
                    "--group-ids",
                    "SecurityGroups",
                ),
                "subnet": ("describe-subnets", "--subnet-ids", "Subnets"),
                "vpc": ("describe-vpcs", "--vpc-ids", "Vpcs"),
                "route-table": (
                    "describe-route-tables",
                    "--route-table-ids",
                    "RouteTables",
                ),
                "internet-gateway": (
                    "describe-internet-gateways",
                    "--internet-gateway-ids",
                    "InternetGateways",
                ),
                "elastic-ip": ("describe-addresses", "--allocation-ids", "Addresses"),
            }
            if kind in by_id:
                cmd, flag, key = by_id[kind]
                return not aws(["ec2", cmd, flag, rid], profile, region).get(key)
            if kind == "security-group-rule":
                return not aws(
                    [
                        "ec2",
                        "describe-security-group-rules",
                        "--security-group-rule-ids",
                        rid,
                    ],
                    profile,
                    region,
                ).get("SecurityGroupRules")
    except RuntimeError as exc:
        return "NotFound" in str(exc) or "does not exist" in str(exc) or "MISSING" in str(exc)
    return False


def short(arn: str) -> str:
    parts = arn.split(":", 5)
    return f"{parts[2]}:{parts[5]}" if len(parts) > 5 else arn


def tags_of(arn: str, service: str, profile: str | None, region: str) -> dict[str, str]:
    """Tags of a resource through the service's own list-tags-for-resource call."""
    answer = aws([service, "list-tags-for-resource", "--resource-arn", arn], profile, region)
    return {t["Key"]: t["Value"] for t in answer.get("Tags", [])}


def collect(
    a: argparse.Namespace,
) -> tuple[list[tuple[str, str]], list[tuple[str, str]], list[tuple[str, str]], list[str]]:
    """Run the checks in every Region; global services (IAM) are read once, in the first Region."""
    suffix = f"-{a.env}"
    left: list[tuple[str, str]] = []  # unexpected
    expected: list[tuple[str, str]] = []  # known residues
    stale: list[tuple[str, str]] = []  # listed by the tagging index but already gone or INACTIVE/STOPPED
    skipped: list[str] = []  # checks that could not run (missing permission)

    def optional(name: str, fn: Callable[[], None]) -> None:
        try:
            fn()
        except RuntimeError as exc:
            if "AccessDenied" in str(exc) or "not authorized" in str(exc):
                skipped.append(name)
            else:
                raise

    for index, region in enumerate(a.region):
        collect_region(a, region, index == 0, suffix, left, expected, stale, optional)
    return left, expected, stale, skipped


def collect_region(
    a: argparse.Namespace,
    region: str,
    first: bool,
    suffix: str,
    left: list[tuple[str, str]],
    expected: list[tuple[str, str]],
    stale: list[tuple[str, str]],
    optional: Callable[[str, Callable[[], None]], None],
) -> None:
    def mine(name: str) -> bool:
        return a.context in name and name.endswith(suffix)

    def ours(tags: dict[str, str]) -> bool:
        return str(tags.get("repo-name", a.repo_name)) == str(a.repo_name)

    tagged = aws(
        [
            "resourcegroupstaggingapi",
            "get-resources",
            "--tag-filters",
            f"Key=repo-name,Values={a.repo_name}",
            f"Key=env-type,Values={a.env}",
        ],
        a.profile,
        region,
    )
    for item in tagged.get("ResourceTagMappingList", []):
        arn = item["ResourceARN"]
        if ":kms:" in arn and ":key/" in arn:
            state = aws(["kms", "describe-key", "--key-id", arn], a.profile, region)["KeyMetadata"]["KeyState"]
            (expected if state == "PendingDeletion" else left).append(("kms key", f"{short(arn)} ({state})"))
        elif is_stale(arn, a.profile, region):
            stale.append(("stale tag index entry", short(arn)))
        else:
            left.append(("tagged resource", short(arn)))

    def schedules() -> None:
        for s in aws(["scheduler", "list-schedules"], a.profile, region).get("Schedules", []):
            if mine(s["Name"]):
                left.append(("scheduler schedule", s["Name"]))

    def task_definitions() -> None:
        fam = aws(["ecs", "list-task-definition-families", "--status", "ACTIVE"], a.profile, region).get("families", [])
        left.extend(("ecs task definition (active)", f) for f in fam if mine(f))

    def iam_roles() -> None:
        for r in aws(["iam", "list-roles"], a.profile, region).get("Roles", []):
            if mine(r["RoleName"]):
                tags = {
                    t["Key"]: t["Value"]
                    for t in aws(["iam", "list-role-tags", "--role-name", r["RoleName"]], a.profile, region).get(
                        "Tags", []
                    )
                }
                if ours(tags):
                    left.append(("iam role", r["RoleName"]))

    def secrets() -> None:
        for s in aws(["secretsmanager", "list-secrets", "--include-planned-deletion"], a.profile, region).get(
            "SecretList", []
        ):
            tags = {t["Key"]: t["Value"] for t in s.get("Tags", [])}
            if mine(s["Name"]) and ours(tags):
                pending = bool(s.get("DeletedDate"))
                bucket = expected if pending and not a.strict_secrets else left
                label = " (scheduled for deletion, the name cannot be reused)" if pending else ""
                bucket.append(("secret", f"{s['Name']} [{region}]{label}"))

    def topics() -> None:
        for topic in aws(["sns", "list-topics"], a.profile, region).get("Topics", []):
            arn = topic["TopicArn"]
            name = arn.rsplit(":", 1)[-1]
            if mine(name) and ours(tags_of(arn, "sns", a.profile, region)):
                left.append(("sns topic", f"{name} [{region}]"))

    def alarms() -> None:
        for alarm in aws(["cloudwatch", "describe-alarms", "--alarm-name-prefix", "alrm-"], a.profile, region).get(
            "MetricAlarms", []
        ):
            if mine(alarm["AlarmName"]) and ours(tags_of(alarm["AlarmArn"], "cloudwatch", a.profile, region)):
                left.append(("alarm", f"{alarm['AlarmName']} [{region}]"))

    def log_groups() -> None:
        for g in aws(
            ["logs", "describe-log-groups", "--log-group-name-pattern", a.context],
            a.profile,
            region,
        ).get("logGroups", []):
            name = g["logGroupName"]
            if name.endswith(suffix) or f"{suffix}/" in name:
                tags = aws(
                    ["logs", "list-tags-for-resource", "--resource-arn", g["arn"].rstrip(":*")],
                    a.profile,
                    region,
                ).get("tags", {})
                if ours(tags):
                    left.append(("log group", f"{name} [{region}]"))

    def cloudfront_origin_access_controls() -> None:
        listed = aws(["cloudfront", "list-origin-access-controls"], a.profile, region)
        for item in listed.get("OriginAccessControlList", {}).get("Items", []):
            if item["Name"].startswith("oac-") and mine(item["Name"]):
                left.append(("cloudfront origin access control", f"{item['Name']} ({item['Id']})"))

    def cloudfront_response_headers_policies() -> None:
        listed = aws(["cloudfront", "list-response-headers-policies", "--type", "custom"], a.profile, region)
        for item in listed.get("ResponseHeadersPolicyList", {}).get("Items", []):
            policy = item["ResponseHeadersPolicy"]
            name = policy["ResponseHeadersPolicyConfig"]["Name"]
            if name.startswith("rhp-") and mine(name):
                left.append(("cloudfront response headers policy", f"{name} ({policy['Id']})"))

    checks: list[tuple[str, Callable[[], None]]] = [
        ("scheduler", schedules),
        ("ecs task definitions", task_definitions),
        ("secrets", secrets),
        ("sns topics", topics),
        ("cloudwatch alarms", alarms),
        ("log groups", log_groups),
    ]
    if first:
        checks.insert(2, ("iam roles", iam_roles))
        # CloudFront is a global service: read once. Names follow oac-/rhp-<region>-<context>-...-<env>.
        checks.append(("cloudfront origin access controls", cloudfront_origin_access_controls))
        checks.append(("cloudfront response headers policies", cloudfront_response_headers_policies))
    for name, fn in checks:
        optional(f"{name} [{region}]", fn)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-name", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--profile")
    ap.add_argument(
        "--region",
        action="append",
        help="Region to check, repeatable (default: us-east-2 and us-east-1)",
    )
    ap.add_argument(
        "--context",
        default="oecalc",
        help="project context segment of the naming convention",
    )
    ap.add_argument(
        "--strict-secrets",
        action="store_true",
        help="a secret scheduled for deletion counts as left over (the CloudFormation destroy force-deletes it)",
    )
    ap.add_argument(
        "--retries",
        type=int,
        default=1,
        help="passes while something is left (deletes can lag)",
    )
    ap.add_argument("--wait", type=int, default=60, help="seconds between passes")
    a = ap.parse_args(argv)
    a.region = a.region or list(DEFAULT_REGIONS)
    try:
        for attempt in range(1, max(a.retries, 1) + 1):
            left, expected, stale, skipped = collect(a)
            if not left or attempt == a.retries:
                break
            print(f"pass {attempt}: {len(left)} left, waiting {a.wait}s", flush=True)
            time.sleep(a.wait)
    except (
        RuntimeError,
        subprocess.TimeoutExpired,
        json.JSONDecodeError,
        KeyError,
    ) as exc:
        print(f"cannot complete the check: {exc}")
        return 2

    print(f"Post-destroy check: repo-name={a.repo_name} env={a.env} regions={','.join(a.region)} (read-only)")
    for title, rows in (
        ("LEFT OVER", left),
        ("Expected residues (not an error)", expected),
        (
            "Tombstones already gone (not an error; the tag index and ECS keep them)",
            stale,
        ),
    ):
        print(f"\n{title}: {len(rows)}")
        counts: dict[str, int] = {}
        for cat, _ in rows:
            counts[cat] = counts.get(cat, 0) + 1
        for cat, n in sorted(counts.items()):
            print(f"  {cat}: {n}")
        if rows is not stale:
            for cat, item in rows[:60]:
                print(f"    - {cat}: {item}")
    if skipped:
        print(f"\nSKIPPED (no permission, not verified): {', '.join(skipped)}")
    print("\nNot covered: Terraform state bucket objects (kept on purpose), the shared add-on artifacts bucket.")
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
