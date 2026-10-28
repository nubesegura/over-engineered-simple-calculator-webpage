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
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import Callable

import e2e_env
import e2e_log
import e2e_redact

EMPTY_BODY_SHA256 = hashlib.sha256(b"").hexdigest()
FIRST_NUMBER = "6"
SECOND_NUMBER = "7"
EXPECTED_SUM = "13"
STEP_TIMEOUT_MS = 20_000
CALCULATE_TIMEOUT_MS = 20_000
REALTIME_MODE_LABEL = "Real-time (WebSocket)"
CONNECTED = "Connected"
LIVE_HISTORY_LIVE = "Live"
LIVE_HISTORY_CONNECTING = "Connecting"
LIVE_HISTORY_TIMEOUT_MS = 10_000
LIVE_HISTORY_UPDATE_TIMEOUT_MS = 3_000
LIVE_HISTORY_PRODUCT_ROW = "6 × 7 = 42"
LIVE_HISTORY_DIVIDE_BY_ZERO_ROW = "1 ÷ 0 = Cannot divide by zero."
LIVE_HISTORY_WEBSOCKET_SUBTITLE = "· websocket"
DIVIDE_BY_ZERO = "Cannot divide by zero."


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


def status_semantics_label(status: str) -> str:
    """Accessible name of the real-time status chip (RealtimeConstants.statusSemanticsLabel in the app)."""
    return f"Connection status: {status}"


def live_history_semantics_label(status: str = LIVE_HISTORY_LIVE) -> str:
    """Accessible name of the live-history status chip (LiveHistoryConstants.statusSemanticsLabel in the app)."""
    return f"Live history status: {status}"


def message_shown(text: str, message: str) -> bool:
    """True when the result line is `Result: <message>` (the app shows real-time errors in the result line)."""
    return text.strip().startswith("Result:") and message in text


def console_leaks(lines: list[str], passwords: list[str]) -> list[str]:
    """Kinds of secret (never values) found in the browser console lines: password, JWT, `token=` or `header-`."""
    return e2e_redact.secret_kinds("\n".join(lines).encode("utf-8"), passwords)


def wait_for_live_history_status(
    page: Any,
    rec: Recorder,
    require_live_history: bool = False,
) -> bool:
    """Wait up to 10s for the History section to reach `Live` when configured (or required)."""
    live_label = live_history_semantics_label(LIVE_HISTORY_LIVE)
    live_locator = (
        page.get_by_text(LIVE_HISTORY_LIVE, exact=True)
        .or_(page.get_by_text(live_label, exact=True))
        .or_(page.get_by_label(live_label, exact=True))
        .first
    )
    try:
        live_locator.wait_for(timeout=LIVE_HISTORY_TIMEOUT_MS)
    except Exception as error:  # noqa: BLE001 - inspect whether live history is configured on this build
        any_chip = page.locator('[aria-label^="Live history status:"]')
        configured = require_live_history or int(any_chip.count()) > 0
        if configured:
            rec.check("live_history_connected", False, type(error).__name__)
        else:
            rec.note("live_history_connected", False, "not configured")
        return False
    rec.check("live_history_connected", True, LIVE_HISTORY_LIVE)
    return True


def verify_live_history_auto_updated(page: Any, rec: Recorder, out: Path | None = None) -> bool:
    """Verify within 3s that both real-time calculations appear in History with `· websocket` without Refresh."""
    try:
        page.get_by_text(LIVE_HISTORY_PRODUCT_ROW).first.wait_for(timeout=LIVE_HISTORY_UPDATE_TIMEOUT_MS)
        page.get_by_text(LIVE_HISTORY_DIVIDE_BY_ZERO_ROW).first.wait_for(timeout=LIVE_HISTORY_UPDATE_TIMEOUT_MS)
        page.get_by_text(LIVE_HISTORY_WEBSOCKET_SUBTITLE).first.wait_for(timeout=LIVE_HISTORY_UPDATE_TIMEOUT_MS)
    except Exception as error:  # noqa: BLE001 - report missing row or timeout as a failed check
        rec.check("live_history_auto_updated", False, type(error).__name__)
        return False
    rec.check(
        "live_history_auto_updated",
        True,
        f"{LIVE_HISTORY_PRODUCT_ROW}; {LIVE_HISTORY_DIVIDE_BY_ZERO_ROW} ({LIVE_HISTORY_WEBSOCKET_SUBTITLE})",
    )
    if out is not None:
        page.screenshot(path=out / "08-live-history-updated.png")
    return True


@dataclass
class SocketTracker:
    """Counts the WebSockets the page opened and how many closed; the URL (it carries the token) is never kept."""

    opened: int = 0
    closed: int = 0

    def track(self, socket: Any) -> None:
        self.opened += 1
        socket.on("close", lambda _socket: self.mark_closed())

    def mark_closed(self) -> None:
        self.closed += 1

    def all_closed(self) -> bool:
        return self.closed >= self.opened

    def summary(self) -> str:
        return f"opened {self.opened}, closed {self.closed}"


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


def calculate(page: Any, first: str, second: str, symbol: str, done: Callable[[str], bool]) -> str:  # pragma: no cover
    """Fill the fields, pick the operation, press Calculate and wait until `done(result line)` or the timeout."""
    page.get_by_role("textbox", name="First Number").fill(first)
    page.get_by_role("textbox", name="Second Number").fill(second)
    page.get_by_role("button", name=symbol, exact=True).click()
    page.get_by_role("button", name="Calculate").click()
    result = page.get_by_text("Result:").first
    result.wait_for(timeout=CALCULATE_TIMEOUT_MS)
    deadline = time.monotonic() + CALCULATE_TIMEOUT_MS / 1000
    text = str(result.inner_text())
    while not done(text) and time.monotonic() < deadline:
        page.wait_for_timeout(500)
        text = str(result.inner_text())
    return text


def use_calculator(page: Any) -> str:  # pragma: no cover - needs a browser
    return calculate(page, FIRST_NUMBER, SECOND_NUMBER, "+", lambda text: result_text_ok(text) or "Error" in text)


def wait_for_sockets_closed(page: Any, sockets: SocketTracker) -> None:  # pragma: no cover - needs a browser
    deadline = time.monotonic() + STEP_TIMEOUT_MS / 1000
    while not sockets.all_closed() and time.monotonic() < deadline:
        page.wait_for_timeout(250)


def run_realtime(
    page: Any,
    rec: Recorder,
    out: Path,
    sockets: SocketTracker,
    live_history_active: bool = False,
) -> None:  # pragma: no cover
    """Real-time mode: connect, 6 x 7 = 42, 1 / 0 shows divide-by-zero, and check live history auto-update."""
    page.get_by_role("button", name=REALTIME_MODE_LABEL).click()
    chip = status_semantics_label(CONNECTED)
    page.get_by_text(chip, exact=True).or_(page.get_by_label(chip, exact=True)).first.wait_for(timeout=STEP_TIMEOUT_MS)
    rec.check("real-time mode shows Connected", True)
    page.screenshot(path=out / "05-realtime-connected.png")

    text = calculate(page, "6", "7", "×", lambda t: result_text_ok(t, "42"))
    rec.check("real-time 6 x 7 shows 42", result_text_ok(text, "42"), text.replace("\n", " ")[:80])
    page.screenshot(path=out / "06-realtime-product.png")

    text = calculate(page, "1", "0", "÷", lambda t: DIVIDE_BY_ZERO in t)
    rec.check("real-time 1 / 0 shows the divide-by-zero text", message_shown(text, DIVIDE_BY_ZERO), text[:80])
    page.screenshot(path=out / "07-realtime-divide-by-zero.png")

    if live_history_active:
        verify_live_history_auto_updated(page, rec, out)


def drive(
    page: Any,
    context: Any,
    site: str,
    email: str,
    password: str,
    rec: Recorder,
    out: Path,
    require_backend: bool,
    sockets: SocketTracker,
    require_live_history: bool = False,
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

    live_history_active = wait_for_live_history_status(page, rec, require_live_history=require_live_history)

    text = use_calculator(page)
    shown = text.replace("\n", " ")[:80]
    if require_backend:
        rec.check("calculation shows the expected result", result_text_ok(text), shown)
    else:
        rec.note("calculation shows the expected result (backend)", result_text_ok(text), shown)
    page.screenshot(path=out / "03-result.png")

    run_realtime(page, rec, out, sockets, live_history_active=live_history_active)

    page.get_by_role("button", name="Log out").click()
    login.wait_for(timeout=STEP_TIMEOUT_MS)
    rec.check("signed out (login page shown again)", True)
    wait_for_sockets_closed(page, sockets)
    rec.check("real-time socket closed after log out", sockets.opened > 0 and sockets.all_closed(), sockets.summary())
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
    parser.add_argument(
        "--require-live-history",
        action="store_true",
        help="fail the run when the History section does not reach Live and auto-update (AppSync Events in dev)",
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
        sockets = SocketTracker()
        console: list[str] = []
        page.on("console", lambda message: console.append(str(message.text)))
        page.on("pageerror", lambda error: console.append(str(error)))
        page.on("websocket", lambda socket: sockets.track(socket))
        try:
            drive(
                page,
                context,
                site,
                args.email,
                password,
                rec,
                run_dir,
                args.require_backend,
                sockets,
                require_live_history=args.require_live_history,
            )
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
    leaks = console_leaks(console, passwords)
    rec.check("no token or token= in the browser console", not leaks, ", ".join(leaks))
    data = rec.save()
    print(json.dumps({k: data[k] for k in ("checks", "informational", "passed")}, indent=2))
    return 0 if data["passed"] else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
