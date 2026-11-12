"""Environment-dependent names shared by the end-to-end tools of the webpage (dev only).

The end-to-end test creates a test user and signs in with it, so it only ever targets dev: every tool takes the
environment through `require_dev`, which refuses anything else (task 3.5 of spec 006).
"""

from __future__ import annotations

import json
from pathlib import Path

ENVIRONMENTS = ("dev", "prod")
DEFAULT_ENV = "dev"
REGION = "us-east-2"
CONTEXT = "oecalc"
REGION_CODE = "useast2"
TEST_EMAIL = "test-user-1@example.com"
REPO_ROOT = Path(__file__).resolve().parents[2]


def require_dev(env: str) -> str:
    """Return env when it is dev; the test user and the recorded sign-in never touch prod."""
    if env != DEFAULT_ENV:
        raise SystemExit(f"the end-to-end test runs in dev only, not {env!r}")
    return env


def profile_name(env: str) -> str:
    return f"tf-local-admin-{env}"


def secrets_file(env: str) -> Path:
    return Path(f".secrets/test-users-{env}.json")


def auth_stack(env: str) -> str:
    return f"stk-{REGION_CODE}-{CONTEXT}-auth-{env}"


def resource(acronym: str, name: str, env: str) -> str:
    """Resource name `<acronym>-useast2-oecalc-<name>-<env>`."""
    return f"{acronym}-{REGION_CODE}-{CONTEXT}-{name}-{env}"


def bff_log_group(env: str) -> str:
    return f"/aws/lambda/{resource('fnc', 'auth-bff', env)}"


def bff_alarm_names(env: str) -> list[str]:
    return [resource("alrm", "auth-bff-errors", env), resource("alrm", "auth-bff-throttles", env)]


def site_url(env: str, repo_root: Path = REPO_ROOT) -> str:
    """https URL of the deployed page, from the DomainName of parameters/<env>.json."""
    data = json.loads((repo_root / "parameters" / f"{env}.json").read_text(encoding="utf-8"))
    return f"https://{data['Parameters']['DomainName']}/"
