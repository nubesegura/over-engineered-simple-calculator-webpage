"""Create (or delete) the Cognito test user of the end-to-end test. DEV ONLY; it CHANGES AWS.

Run it yourself, or with the owner's authorization at that moment. The password is random, written to
``.secrets/test-users-dev.json`` (mode 600) and never printed. A user already listed in the file and present in the
pool is left untouched, so a second run changes nothing. The pool id comes from the auth stack output.

Usage (from the repository root):
    python scripts/e2e/create_test_user.py [--profile X] [--region R] [--email test-user-1@example.com]
    python scripts/e2e/create_test_user.py --delete
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import string
import sys
from pathlib import Path
from typing import Any

import e2e_env

PASSWORD_LENGTH = 24
# Subset of the symbols Cognito accepts as "special characters".
SYMBOLS = "!@#%^*-_=+"


def generate_password(length: int = PASSWORD_LENGTH) -> str:
    """Random password with at least one lower, upper, digit and symbol (pool policy)."""
    pools = (string.ascii_lowercase, string.ascii_uppercase, string.digits, SYMBOLS)
    chars = [secrets.choice(pool) for pool in pools]
    alphabet = "".join(pools)
    chars += [secrets.choice(alphabet) for _ in range(length - len(chars))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def user_exists(client: Any, pool_id: str, email: str) -> bool:
    try:
        client.admin_get_user(UserPoolId=pool_id, Username=email)
    except client.exceptions.UserNotFoundException:
        return False
    return True


def load_credentials(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {str(email): str(password) for email, password in data.items()}


def write_credentials(path: Path, credentials: dict[str, str]) -> None:
    """Write the file with mode 600 from the first byte (no world-readable window)."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(credentials, indent=2) + "\n")
    path.chmod(0o600)  # also fixes the mode of a pre-existing file


def ensure_user(client: Any, pool_id: str, email: str, secrets_file: Path) -> bool:
    """Make the user exist with a known password; True when something changed."""
    credentials = load_credentials(secrets_file)
    if email in credentials and user_exists(client, pool_id, email):
        return False
    password = generate_password()
    if not user_exists(client, pool_id, email):
        client.admin_create_user(
            UserPoolId=pool_id,
            Username=email,
            UserAttributes=[
                {"Name": "email", "Value": email},
                {"Name": "email_verified", "Value": "true"},
            ],
            MessageAction="SUPPRESS",  # no invitation email
        )
    client.admin_set_user_password(UserPoolId=pool_id, Username=email, Password=password, Permanent=True)
    credentials[email] = password
    write_credentials(secrets_file, credentials)
    return True


def delete_user(client: Any, pool_id: str, email: str, secrets_file: Path) -> bool:
    """Remove the user from the pool and from the secrets file; True when the user existed in the pool."""
    existed = user_exists(client, pool_id, email)
    if existed:
        client.admin_delete_user(UserPoolId=pool_id, Username=email)
    credentials = load_credentials(secrets_file)
    if credentials.pop(email, None) is not None:
        write_credentials(secrets_file, credentials)
    return existed


def pool_id_from_stack(session: Any, stack_name: str) -> str:
    stack = session.client("cloudformation").describe_stacks(StackName=stack_name)["Stacks"][0]
    for output in stack.get("Outputs", []):
        if output["OutputKey"] == "UserPoolId":
            return str(output["OutputValue"])
    raise SystemExit(f"Stack {stack_name} has no UserPoolId output")


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - needs AWS
    import boto3  # imported here so the unit tests of the helpers need no AWS configuration

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--env", default=e2e_env.DEFAULT_ENV, help="dev only (prod is refused)")
    parser.add_argument("--email", default=e2e_env.TEST_EMAIL)
    parser.add_argument("--delete", action="store_true", help="delete the user and its entry in the secrets file")
    parser.add_argument("--profile", help="AWS profile (default: tf-local-admin-dev)")
    parser.add_argument("--region", default=e2e_env.REGION)
    args = parser.parse_args(argv)
    env = e2e_env.require_dev(args.env)
    secrets_file = e2e_env.secrets_file(env)
    session = boto3.Session(profile_name=args.profile or e2e_env.profile_name(env), region_name=args.region)
    pool_id = pool_id_from_stack(session, e2e_env.auth_stack(env))
    client = session.client("cognito-idp")
    if args.delete:
        print("deleted" if delete_user(client, pool_id, args.email, secrets_file) else "nothing to delete")
        return 0
    if ensure_user(client, pool_id, args.email, secrets_file):
        print(f"Created {args.email}; password written to {secrets_file} (mode 600)")
    else:
        print("Nothing to do: the test user already exists")
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
