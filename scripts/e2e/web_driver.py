"""Recorded end-to-end run of the deployed webpage in dev: sign in, calculate, sign out, check the refusal.

Usage (from the repository root, after create_test_user.py):
    python scripts/e2e/web_driver.py [--record] [--headless] [--run-dir e2e-runs/<UTC date>-<UTC time>]

Opens the page in a visible Chromium (Playwright), turns on the Flutter accessibility tree, signs in with the test user
of ``.secrets/test-users-dev.json``, uses the calculator, signs out and checks that /auth/refresh refuses the session.
Writes into the run folder: run.log (one line per step, secret guard), results.json (start/end time, checks),
trace.zip (redacted), screenshots, and recording.mp4 with --record (ffmpeg, recorder.py).
The password is never printed or logged; trace and summary are redacted and rescanned at the end. Dev only.

Exit codes: 0 every check passed, 1 a check failed, 2 usage or setup error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import e2e_env
import e2e_log
import e2e_redact

EMPTY_BODY_SHA256 = hashlib.sha256(b"").hexdigest()
FIRST_NUMBER = "6"
SECOND_NUMBER = "7"
EXPECTED_SUM = "13"
STEP_TIMEOUT_MS = 20_000
CALCULATE_TIMEOUT_MS = 20_000


def run_dir_name(now: datetime | None = None) -> str:
    """Folder name `<UTC date>-<UTC time>`."""
    return (now or datetime.now(UTC)).astimezone(UTC).strftime("%Y-%m-%d-%H%M%S")


def load_password(secrets_file: Path, email: str) -> str:
    try:
        data = json.loads(secrets_file.read_text(encoding="utf-8"))
        return str(data[email])
    except (OSError, ValueError, KeyError):
        raise SystemExit(f"no password for the test user in {secrets_file}; run create_test_user.py first") from None


def result_text_ok(text: str, expected: str = EXPECTED_SUM) -> bool:
    """True when the calculator shows `Result: <expected>` (number formatting ignored: 13 or 13.0)."""
    prefix = "Result:"
    if prefix not in text:
        return False
    value = text.split(prefix, 1)[1].strip().split()[0] if text.split(prefix, 1)[1].strip() else ""
    try:
        return float(value) == float(expected)
    except ValueError:
        return False


def refusal_ok(status: int, content_type: str) -> bool:
    """After sign-out /auth/refresh must refuse with a JSON error (a 200 HTML page is the SPA fallback)."""
    return status in (400, 401, 403) and "json" in content_type.lower()


@dataclass
class Recorder:
    """Run log + checks of one run; every line goes through the secret guard."""

    run_dir: Path
    passwords: list[str]
    checks: dict[str, bool] = field(default_factory=dict)
    informational: dict[str, bool] = field(default_factory=dict)
    started_at: str = field(default_factory=lambda: datetime.now(UTC).isoformat(timespec="seconds"))
    step: int = 0

    def log(self, action: str, result: str, detail: str = "") -> None:
        self.step += 1
        e2e_log.write_line(self.run_dir / "run.log", [f"{self.step:02d}", action, result, detail], self.passwords)

    def check(self, name: str, passed: bool, detail: str = "") -> None:
        self.checks[name] = passed
        self.log(name, "ok" if passed else "FAILED", detail)

    def note(self, name: str, passed: bool, detail: str = "") -> None:
        """Result that is reported but does not decide the run (it depends on something outside this stack)."""
        self.informational[name] = passed
        self.log(name, "ok" if passed else "NOT OK (informational)", detail)

    def save(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "started_at": self.started_at,
            "ended_at": datetime.now(UTC).isoformat(timespec="seconds"),
            "checks": self.checks,
            "informational": self.informational,
            "passed": bool(self.checks) and all(self.checks.values()),
        }
        (self.run_dir / "results.json").write_bytes((json.dumps(data, indent=2) + "\n").encode("utf-8"))
        return data


def enable_semantics(page: Any) -> None:  # pragma: no cover - needs a browser
    """Flutter web draws on a canvas; the accessibility tree (what Playwright can see) is off until this is clicked."""
    page.locator("flt-semantics-placeholder").dispatch_event("click")


def sign_in(page: Any, email: str, password: str) -> None:  # pragma: no cover - needs a browser
    page.get_by_role("textbox", name="Email").fill(email)
    page.get_by_role("textbox", name="Password").fill(password)
    page.get_by_role("button", name="Log in").click()


def use_calculator(page: Any) -> str:  # pragma: no cover - needs a browser
    page.get_by_role("textbox", name="First Number").fill(FIRST_NUMBER)
    page.get_by_role("textbox", name="Second Number").fill(SECOND_NUMBER)
    page.get_by_role("button", name="+").click()
    page.get_by_role("button", name="Calculate").click()
    result = page.get_by_text("Result:").first
    result.wait_for(timeout=CALCULATE_TIMEOUT_MS)
    deadline = time.monotonic() + CALCULATE_TIMEOUT_MS / 1000
    text = str(result.inner_text())
    while not result_text_ok(text) and "Error" not in text and time.monotonic() < deadline:
        page.wait_for_timeout(500)
        text = str(result.inner_text())
    return text


def drive(
    page: Any, context: Any, site: str, email: str, password: str, rec: Recorder, out: Path, require_backend: bool
) -> None:  # pragma: no cover
    page.goto(site, wait_until="load")
    enable_semantics(page)
    login = page.get_by_role("button", name="Log in")
    login.wait_for(timeout=STEP_TIMEOUT_MS)
    rec.check("login page shown", True)
    page.screenshot(path=out / "01-login.png")

    sign_in(page, email, password)
    page.get_by_role("button", name="Log out").wait_for(timeout=STEP_TIMEOUT_MS)
    cookies = context.cookies()
    refresh = [c for c in cookies if "refresh" in c["name"].lower() or c.get("httpOnly")]
    rec.check("signed in (calculator shown)", True)
    rec.check(
        "session cookie is HttpOnly and Secure", bool(refresh) and all(c["httpOnly"] and c["secure"] for c in refresh)
    )
    page.screenshot(path=out / "02-calculator.png")

    text = use_calculator(page)
    shown = text.replace("\n", " ")[:80]
    if require_backend:
        rec.check("calculation shows the expected result", result_text_ok(text), shown)
    else:
        rec.note("calculation shows the expected result (backend)", result_text_ok(text), shown)
    page.screenshot(path=out / "03-result.png")

    page.get_by_role("button", name="Log out").click()
    login.wait_for(timeout=STEP_TIMEOUT_MS)
    rec.check("signed out (login page shown again)", True)
    page.screenshot(path=out / "04-signed-out.png")

    response = context.request.post(
        site + "auth/refresh",
        headers={"X-Requested-With": "XMLHttpRequest", "x-amz-content-sha256": EMPTY_BODY_SHA256},
    )
    rec.check(
        "refresh is refused after sign-out",
        refusal_ok(response.status, response.headers.get("content-type", "")),
        f"status {response.status}",
    )


def start_recording(run_dir: Path) -> None:  # pragma: no cover - needs ffmpeg and a display
    import recorder

    recorder.main(["start", str(run_dir / "recording.mp4")])


def stop_recording(run_dir: Path) -> None:  # pragma: no cover
    import recorder

    recorder.main(["stop", str(run_dir / "recording.mp4")])


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - needs a browser and the deployed page
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--env", default=e2e_env.DEFAULT_ENV, help="dev only (prod is refused)")
    parser.add_argument("--email", default=e2e_env.TEST_EMAIL)
    parser.add_argument("--run-dir", type=Path, default=None)
    parser.add_argument("--record", action="store_true", help="record the screen with ffmpeg")
    parser.add_argument(
        "--require-backend",
        action="store_true",
        help="fail the run when the calculation does not return the expected result (needs the dev API deployed)",
    )
    parser.add_argument("--headless", action="store_true", help="no visible window (not recordable)")
    args = parser.parse_args(argv)
    env = e2e_env.require_dev(args.env)
    password = load_password(e2e_env.secrets_file(env), args.email)
    site = e2e_env.site_url(env)
    run_dir = (args.run_dir or Path("e2e-runs") / run_dir_name()).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    passwords = [password]
    rec = Recorder(run_dir, passwords)
    rec.log("start", "ok", f"env {env}")
    if args.record:
        start_recording(run_dir)
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print(
            "playwright is not installed: pip install -r scripts/e2e/requirements-e2e.txt; playwright install chromium",
            file=sys.stderr,
        )
        return 2
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=args.headless, args=["--start-maximized"])
        context = browser.new_context(no_viewport=True)
        context.tracing.start(screenshots=True, snapshots=False, sources=False)
        page = context.new_page()
        try:
            drive(page, context, site, args.email, password, rec, run_dir, args.require_backend)
        except Exception as error:  # noqa: BLE001 - a failed step is a failed check, not a crash
            rec.check("run completed without exception", False, type(error).__name__)
            page.screenshot(path=run_dir / "failure.png")
        finally:
            context.tracing.stop(path=run_dir / "trace.zip")
            browser.close()
            if args.record:
                stop_recording(run_dir)
    e2e_redact.redact_trace(run_dir / "trace.zip", passwords)
    found = e2e_redact.scan_folder(run_dir, passwords)
    rec.check("no secrets in the run folder", not found, ", ".join(sorted(found))[:200])
    data = rec.save()
    print(json.dumps({k: data[k] for k in ("checks", "informational", "passed")}, indent=2))
    return 0 if data["passed"] else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
