"""Append one line to the run log of the end-to-end test.

Usage (command line):
    python e2e_log.py <log path> <step> <action> <result> [detail]

Line format (one per action, fields separated by " | "):
    2026-10-14T12:00:00.123Z | 05 | calc compute "10 / 2" | ok exit 0 | 5 txId 3f0c...-uuid

The time is UTC, ISO-8601 with milliseconds. Empty optional fields are written as "-".

Secret guard: the line is refused (exit 3, nothing written) when a value contains a test-user password (read from the
file named by E2E_SECRETS_FILE, never printed), a JWT, a long opaque token (40 or more characters that is not a UUID)
or a standalone 12-digit number (possible AWS account id). The driver imports `write_line` and uses the same guard.

Exit codes: 0 written, 2 usage error, 3 refused by the secret guard.
"""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

SEPARATOR = " | "
JWT = re.compile(r"eyJ[\w-]{10,}\.[\w-]+")
OPAQUE_TOKEN = re.compile(r"[A-Za-z0-9_.+/=-]{40,}")
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
ACCOUNT_ID = re.compile(r"(?<!\d)\d{12}(?!\d)")
USAGE = "usage: python e2e_log.py <log path> <step> <action> <result> [detail]"


class RefusedLineError(ValueError):
    """The line was not written because it looks like it carries a secret."""


def known_secrets() -> list[str]:
    """Passwords of the test users when E2E_SECRETS_FILE names the secrets file; empty otherwise. Never printed."""
    path = os.environ.get("E2E_SECRETS_FILE", "").strip()
    if not path:
        return []
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [str(value) for value in data.values() if str(value)]


def looks_secret(value: str, secrets: list[str]) -> str | None:
    """Reason why the value must not be logged, or None when it is safe."""
    if any(secret in value for secret in secrets):
        return "it contains a test-user password"
    if JWT.search(value):
        return "it contains a JWT"
    for token in OPAQUE_TOKEN.findall(value):
        if not UUID.match(token):
            return "it contains a long opaque token"
    if ACCOUNT_ID.search(value):
        return "it contains a 12-digit number (possible AWS account id)"
    return None


def clean(value: str) -> str:
    """One-line field: no newlines, no separator, "-" when empty."""
    text = " ".join(value.split()).replace("|", "/")
    return text or "-"


def build_line(fields: list[str], now: datetime | None = None) -> str:
    """Format one log line from step, action, result and detail."""
    moment = (now or datetime.now(UTC)).astimezone(UTC)
    stamp = moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"
    padded = [*fields, ""][:4]
    return SEPARATOR.join([stamp, *(clean(item) for item in padded)])


def write_line(log_path: Path, fields: list[str], secrets: list[str] | None = None) -> str:
    """Apply the guard and append the line; raise RefusedLineError when a field looks secret."""
    guard = known_secrets() if secrets is None else secrets
    for position, value in enumerate(fields, start=1):
        reason = looks_secret(value, guard)
        if reason:
            raise RefusedLineError(f"field {position} was not logged because {reason}")
    line = build_line(fields)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("ab") as handle:
        handle.write((line + "\n").encode("utf-8"))
    return line


def main(argv: list[str]) -> int:
    """Validate the arguments, apply the secret guard and append the line."""
    if len(argv) < 4 or len(argv) > 5:
        print(USAGE, file=sys.stderr)
        return 2
    fields = argv[1:]
    if not all(item.strip() for item in fields[:3]):
        print("step, action and result must not be empty\n" + USAGE, file=sys.stderr)
        return 2
    try:
        print(write_line(Path(argv[0]), fields))
    except RefusedLineError as refused:
        print(f"refused: {refused}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
