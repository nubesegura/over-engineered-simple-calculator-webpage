"""Collect the CloudWatch logs and alarm state of an end-to-end run of the webpage (dev). READ ONLY.

Usage:
    python scripts/e2e/collect_logs.py --run-dir <run folder> [--profile P]
        [--region us-east-2] [--wait 60]

Reads results.json of the run folder (start and end times), waits --wait seconds for log ingestion, then reads the
log group of the BFF function (filter-log-events in the run window, one minute of margin) and the state of its two
alarms (errors, throttles). Writes into <run folder>/logs/: lambda-auth-bff.jsonl (one sanitized event per line) and
summary.json (counts, ERROR lines, alarm states, checks).

CloudFront standard logging and WAF logging are not enabled in this stack, so there is nothing to collect on that side.

Sanitizing: 12-digit numbers become ************, JWTs become <jwt>, the test-user password becomes <password>. If a
password or a JWT was in the raw logs, the check "no secrets in logs" fails: that is a finding, not something to hide.

Exit codes: 0 every check passed, 1 a check failed, 2 usage or AWS error.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import e2e_env

ACCOUNT_ID = re.compile(r"(?<!\d)\d{12}(?!\d)")
JWT = re.compile(r"eyJ[\w-]{10,}\.[\w-]+\.[\w-]*")
MARGIN = timedelta(minutes=1)


def parse_time(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def sanitize(message: str, passwords: list[str]) -> tuple[str, list[str]]:
    """Masked copy of the message and the kinds of secret that were found in it."""
    found: list[str] = []
    for password in passwords:
        if password and password in message:
            message = message.replace(password, "<password>")
            found.append("password")
    if JWT.search(message):
        found.append("jwt")
        message = JWT.sub("<jwt>", message)
    return ACCOUNT_ID.sub("************", message), found


def read_events(logs: Any, group: str, start: datetime, end: datetime) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {
        "logGroupName": group,
        "startTime": int(start.timestamp() * 1000),
        "endTime": int(end.timestamp() * 1000),
    }
    while True:
        page = logs.filter_log_events(**kwargs)
        events.extend(page.get("events", []))
        token = page.get("nextToken")
        if not token or token == kwargs.get("nextToken"):
            return events
        kwargs["nextToken"] = token


def write_jsonl(path: Path, events: list[dict[str, Any]], passwords: list[str]) -> tuple[list[str], list[str]]:
    """Write the sanitized events; return the messages and the secret kinds found."""
    lines, messages, found = [], [], []
    for event in events:
        message, kinds = sanitize(event.get("message", "").rstrip(), passwords)
        found.extend(kinds)
        messages.append(message)
        stamp = datetime.fromtimestamp(event["timestamp"] / 1000, UTC).isoformat(timespec="milliseconds")
        lines.append(json.dumps({"timestamp": stamp, "stream": event.get("logStreamName", ""), "message": message}))
    path.write_bytes(("\n".join(lines) + ("\n" if lines else "")).encode("utf-8"))
    return messages, found


def error_lines(messages: list[str]) -> list[str]:
    """Lines at ERROR level (JSON logs, Lambda runtime errors)."""
    hits = []
    for message in messages:
        compact = message.replace(" ", "")
        if '"level":"ERROR"' in compact or '"log_level":"ERROR"' in compact or message.startswith(("[ERROR]", "ERROR")):
            hits.append(message[:500])
    return hits


def build_summary(
    events: list[dict[str, Any]],
    messages: list[str],
    found: list[str],
    alarms: dict[str, str],
    window: tuple[datetime, datetime],
    log_group: str,
) -> dict[str, Any]:
    errors = error_lines(messages)
    checks = {
        "BFF logs present": len(events) > 0,
        "no secrets in logs": not found,
        "no ERROR lines in the BFF logs": not errors,
        "both alarms exist": all(state != "NOT_FOUND" for state in alarms.values()),
        "no alarm in ALARM": all(state != "ALARM" for state in alarms.values()),
    }
    return {
        "window": {"start": window[0].isoformat(), "end": window[1].isoformat()},
        "log_group": log_group,
        "events": len(events),
        "error_lines": errors[:20],
        "secrets_found": sorted(set(found)),
        "alarms": alarms,
        "checks": checks,
        "passed": all(checks.values()),
    }


def alarm_states(cloudwatch: Any, names: list[str]) -> dict[str, str]:
    found = {a["AlarmName"]: a["StateValue"] for a in cloudwatch.describe_alarms(AlarmNames=names)["MetricAlarms"]}
    return {name: found.get(name, "NOT_FOUND") for name in names}


def main(argv: list[str]) -> int:  # pragma: no cover - needs AWS
    import boto3

    parser = argparse.ArgumentParser(description="Collect CloudWatch logs of an e2e run (read only).")
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--env", default=e2e_env.DEFAULT_ENV, help="dev only (prod is refused)")
    parser.add_argument("--profile", default=None, help="AWS profile (default: tf-local-admin-dev)")
    parser.add_argument("--region", default=e2e_env.REGION)
    parser.add_argument("--wait", type=int, default=60, help="seconds to wait for log ingestion")
    args = parser.parse_args(argv)
    env = e2e_env.require_dev(args.env)
    try:
        results = json.loads((args.run_dir / "results.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print(f"no results.json in {args.run_dir}; run web_driver.py first", file=sys.stderr)
        return 2
    try:
        passwords = [str(v) for v in json.loads(e2e_env.secrets_file(env).read_text(encoding="utf-8")).values()]
    except (OSError, ValueError):
        passwords = []
    window = (parse_time(results["started_at"]) - MARGIN, parse_time(results["ended_at"]) + MARGIN)
    time.sleep(max(args.wait, 0))
    session = boto3.Session(profile_name=args.profile or e2e_env.profile_name(env), region_name=args.region)
    group = e2e_env.bff_log_group(env)
    try:
        events = read_events(session.client("logs"), group, *window)
        alarms = alarm_states(session.client("cloudwatch"), e2e_env.bff_alarm_names(env))
    except Exception as error:  # noqa: BLE001 - report any AWS error and stop
        print(f"AWS error: {ACCOUNT_ID.sub('************', str(error))[:400]}", file=sys.stderr)
        return 2
    out = args.run_dir / "logs"
    out.mkdir(parents=True, exist_ok=True)
    messages, found = write_jsonl(out / "lambda-auth-bff.jsonl", events, passwords)
    summary = build_summary(events, messages, found, alarms, window, group)
    (out / "summary.json").write_bytes(json.dumps(summary, indent=2).encode("utf-8"))
    print(json.dumps({k: summary[k] for k in ("checks", "passed", "secrets_found")}, indent=2))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
