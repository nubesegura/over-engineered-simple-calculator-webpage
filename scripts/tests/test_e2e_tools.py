"""Offline tests of the end-to-end helpers (no browser, no AWS, no network)."""

from __future__ import annotations

import json
import os
import zipfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

import collect_logs
import create_test_user
import e2e_env
import e2e_log
import e2e_redact
import web_driver

PASSWORD = "Zx9!correct-horse-Battery"  # noqa: S105 - fake
JWT = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl"


class Pool:
    """Fake cognito-idp client."""

    class exceptions:  # noqa: N801 - mirrors boto3
        class UserNotFoundException(Exception):  # noqa: N818
            pass

    def __init__(self, users: set[str] | None = None) -> None:
        self.users = users or set()
        self.passwords: dict[str, str] = {}

    def admin_get_user(self, UserPoolId: str, Username: str) -> dict[str, Any]:
        if Username not in self.users:
            raise self.exceptions.UserNotFoundException
        return {}

    def admin_create_user(self, **kwargs: Any) -> None:
        assert kwargs["MessageAction"] == "SUPPRESS"
        self.users.add(kwargs["Username"])

    def admin_set_user_password(self, UserPoolId: str, Username: str, Password: str, Permanent: bool) -> None:
        assert Permanent
        self.passwords[Username] = Password

    def admin_delete_user(self, UserPoolId: str, Username: str) -> None:
        self.users.discard(Username)


# --- environment ------------------------------------------------------------------------------------------------


def test_prod_is_refused() -> None:
    with pytest.raises(SystemExit):
        e2e_env.require_dev("prod")
    assert e2e_env.require_dev("dev") == "dev"


def test_names_follow_the_templates() -> None:
    assert e2e_env.auth_stack("dev") == "stk-useast2-oecalc-auth-dev"
    assert e2e_env.bff_log_group("dev") == "/aws/lambda/fnc-useast2-oecalc-auth-bff-dev"
    assert e2e_env.bff_alarm_names("dev") == [
        "alrm-useast2-oecalc-auth-bff-errors-dev",
        "alrm-useast2-oecalc-auth-bff-throttles-dev",
    ]


def test_site_url_reads_the_dev_parameters() -> None:
    url = e2e_env.site_url("dev")
    assert url.startswith("https://") and url.endswith("/") and ".dev." in url


# --- test user ----------------------------------------------------------------------------------------------------


def test_generated_password_meets_the_pool_policy() -> None:
    password = create_test_user.generate_password()
    assert len(password) == create_test_user.PASSWORD_LENGTH
    assert any(c.islower() for c in password) and any(c.isupper() for c in password)
    assert any(c.isdigit() for c in password) and any(c in create_test_user.SYMBOLS for c in password)


def test_ensure_user_creates_once_and_is_idempotent(tmp_path: Path) -> None:
    pool, file = Pool(), tmp_path / ".secrets" / "test-users-dev.json"
    assert create_test_user.ensure_user(pool, "pool", "a@example.com", file) is True
    assert create_test_user.ensure_user(pool, "pool", "a@example.com", file) is False
    assert json.loads(file.read_text(encoding="utf-8"))["a@example.com"] == pool.passwords["a@example.com"]
    if os.name != "nt":
        assert file.stat().st_mode & 0o777 == 0o600


def test_ensure_user_repairs_a_user_missing_from_the_file(tmp_path: Path) -> None:
    pool, file = Pool({"a@example.com"}), tmp_path / "s.json"
    assert create_test_user.ensure_user(pool, "pool", "a@example.com", file) is True
    assert "a@example.com" in create_test_user.load_credentials(file)


def test_delete_user_removes_pool_user_and_file_entry(tmp_path: Path) -> None:
    pool, file = Pool(), tmp_path / "s.json"
    create_test_user.ensure_user(pool, "pool", "a@example.com", file)
    assert create_test_user.delete_user(pool, "pool", "a@example.com", file) is True
    assert pool.users == set() and create_test_user.load_credentials(file) == {}
    assert create_test_user.delete_user(pool, "pool", "a@example.com", file) is False


def test_pool_id_from_stack() -> None:
    class Cfn:
        def describe_stacks(self, StackName: str) -> dict[str, Any]:
            return {"Stacks": [{"Outputs": [{"OutputKey": "UserPoolId", "OutputValue": "us-east-2_x"}]}]}

    class Session:
        def client(self, name: str) -> Cfn:
            return Cfn()

    assert create_test_user.pool_id_from_stack(Session(), "s") == "us-east-2_x"

    class Empty(Cfn):
        def describe_stacks(self, StackName: str) -> dict[str, Any]:
            return {"Stacks": [{}]}

    class EmptySession:
        def client(self, name: str) -> Cfn:
            return Empty()

    with pytest.raises(SystemExit):
        create_test_user.pool_id_from_stack(EmptySession(), "s")


# --- secret guard and redaction ---------------------------------------------------------------------------------


def test_run_log_refuses_secrets(tmp_path: Path) -> None:
    log = tmp_path / "run.log"
    for value in (f"typed {PASSWORD}", f"token {JWT}", "account 123456789012", "x" * 45):
        with pytest.raises(e2e_log.RefusedLineError):
            e2e_log.write_line(log, ["01", "step", "ok", value], [PASSWORD])
    assert not log.exists()
    line = e2e_log.write_line(log, ["01", "step", "ok", "fine"], [PASSWORD])
    assert line.endswith("| 01 | step | ok | fine") and log.read_text(encoding="utf-8").count("\n") == 1


def test_redact_bytes_masks_password_jwt_and_headers() -> None:
    raw = (
        f'{{"value":"{PASSWORD}"}} {JWT} {{"name":"Set-Cookie","value":"refresh_token=abc123; Secure"}} '
        '{"name":"authorization","value":"Bearer x"} {"name":"Authorization","value":"Bearer y"}'
    ).encode()
    out = e2e_redact.redact_bytes(raw, [PASSWORD])
    for secret in (PASSWORD, JWT, "abc123", "Bearer"):
        assert secret.encode() not in out
    assert b"<password>" in out and b"<jwt>" in out


def test_redact_trace_rewrites_every_member_and_scan_finds_nothing(tmp_path: Path) -> None:
    trace = tmp_path / "trace.zip"
    with zipfile.ZipFile(trace, "w") as archive:
        archive.writestr("0-trace.trace", f'fill "{PASSWORD}"')
        archive.writestr("0-trace.network", f'{{"name":"Cookie","value":"id_token={JWT}"}}')
    assert set(e2e_redact.scan_folder(tmp_path, [PASSWORD])) == {"trace.zip!0-trace.trace", "trace.zip!0-trace.network"}
    e2e_redact.redact_trace(trace, [PASSWORD])
    assert e2e_redact.scan_folder(tmp_path, [PASSWORD]) == {}
    with zipfile.ZipFile(trace) as archive:
        assert archive.read("0-trace.trace") == b'fill "<password>"'


def test_scan_reports_kinds_without_values(tmp_path: Path) -> None:
    (tmp_path / "a.log").write_text(f"{PASSWORD} {JWT}", encoding="utf-8")
    (tmp_path / "clip.mp4").write_bytes(PASSWORD.encode())  # binary files are not scanned
    found = e2e_redact.scan_folder(tmp_path, [PASSWORD])
    assert found == {"a.log": ["password", "jwt"]}
    assert PASSWORD not in json.dumps(found)


# --- driver helpers ----------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "ok"),
    [
        ("Result: 13", True),
        ("Result: 13.0", True),
        ("Result: 13\nBackend: x", True),
        ("Result: 14", False),
        ("Result:", False),
        ("Result: error", False),
        ("nothing", False),
    ],
)
def test_result_text_ok(text: str, ok: bool) -> None:
    assert web_driver.result_text_ok(text) is ok


@pytest.mark.parametrize(
    ("status", "ctype", "ok"),
    [
        (401, "application/json", True),
        (403, "application/json; charset=utf-8", True),
        (200, "text/html", False),
        (401, "text/html", False),
        (200, "application/json", False),
    ],
)
def test_refusal_ok(status: int, ctype: str, ok: bool) -> None:
    assert web_driver.refusal_ok(status, ctype) is ok


def test_status_semantics_label() -> None:
    assert web_driver.status_semantics_label("Connected") == "Connection status: Connected"


@pytest.mark.parametrize(
    ("text", "ok"),
    [
        ("Result: Cannot divide by zero.", True),
        ("Result: 0", False),
        ("Cannot divide by zero.", False),
    ],
)
def test_message_shown(text: str, ok: bool) -> None:
    assert web_driver.message_shown(text, "Cannot divide by zero.") is ok


def test_result_text_ok_accepts_other_expected_value() -> None:
    assert web_driver.result_text_ok("Result: 42.0", "42") is True
    assert web_driver.result_text_ok("Result: 13", "42") is False


class FakeSocket:
    def __init__(self) -> None:
        self.on_close: Any = None

    def on(self, event: str, handler: Any) -> None:
        assert event == "close"
        self.on_close = handler


def test_socket_tracker_counts_open_and_closed() -> None:
    tracker = web_driver.SocketTracker()
    first, second = FakeSocket(), FakeSocket()
    tracker.track(first)
    tracker.track(second)
    assert not tracker.all_closed()
    first.on_close(first)
    second.on_close(second)
    assert tracker.all_closed() and tracker.summary() == "opened 2, closed 2"


def test_token_search_detects_planted_fake_token() -> None:
    """Self-test: the leak search must flag a planted token in the console lines and in a run folder."""
    planted_url = f"wss://ws.example.invalid/dev?token={JWT}"
    assert set(web_driver.console_leaks(["connected", planted_url], [PASSWORD])) == {"jwt", "token-query"}
    assert set(web_driver.console_leaks(["opening wss://ws.example.invalid/dev?token=abc"], [])) == {"token-query"}
    assert web_driver.console_leaks(["Connected", "Result: 42"], [PASSWORD]) == []


def test_token_search_in_run_folder_and_redacted_value(tmp_path: Path) -> None:
    (tmp_path / "console.log").write_text("GET wss://ws.example.invalid/dev?token=fake-value", encoding="utf-8")
    assert e2e_redact.scan_folder(tmp_path, []) == {"console.log": ["token-query"]}
    (tmp_path / "console.log").write_text("Set-Cookie: idtoken=<redacted>", encoding="utf-8")
    assert e2e_redact.scan_folder(tmp_path, []) == {}


def test_redact_masks_query_token_and_scan_passes() -> None:
    raw = f'{{"url":"wss://ws.example.invalid/dev?a=1&token={JWT}&b=2"}} x?token%3Dabc \u0026token=def'.encode()
    masked = e2e_redact.redact_bytes(raw, [])
    assert JWT.encode() not in masked and b"abc" not in masked and b"def" not in masked
    assert b"token=<redacted>&b=2" in masked
    assert e2e_redact.secret_kinds(masked, []) == []
    assert "token-query" in e2e_redact.secret_kinds(raw, [])


@pytest.mark.parametrize(
    "text", ["csrf_token=abc", "next_page_token=xyz", "access_token=q", "a.token=1;", "id_token=z"]
)
def test_other_token_names_do_not_fire(text: str) -> None:
    assert "token-query" not in e2e_redact.secret_kinds(text.encode(), [])
    assert "token-query" not in web_driver.console_leaks([text], [])


def test_scan_skips_trace_resources_but_scans_events(tmp_path: Path) -> None:
    with zipfile.ZipFile(tmp_path / "trace.zip", "w") as archive:
        archive.writestr("resources/abc123", "var u = '?token=' + value; fetch('/x?token=a')")
        archive.writestr("0-trace.network", "GET wss://ws.example.invalid/dev?token=fake")
    assert e2e_redact.scan_folder(tmp_path, []) == {"trace.zip!0-trace.network": ["token-query"]}


def test_run_dir_name_is_utc() -> None:
    assert web_driver.run_dir_name(datetime(2026, 10, 25, 3, 4, 5, tzinfo=UTC)) == "2026-10-25-030405"


def test_load_password(tmp_path: Path) -> None:
    file = tmp_path / "s.json"
    with pytest.raises(SystemExit):
        web_driver.load_password(file, "a@example.com")
    file.write_text(json.dumps({"a@example.com": PASSWORD}), encoding="utf-8")
    assert web_driver.load_password(file, "a@example.com") == PASSWORD
    with pytest.raises(SystemExit):
        web_driver.load_password(file, "b@example.com")


def test_recorder_logs_checks_and_saves(tmp_path: Path) -> None:
    rec = web_driver.Recorder(tmp_path, [PASSWORD])
    rec.check("one", True)
    assert rec.save()["passed"] is True
    rec.check("two", False, "detail")
    data = rec.save()
    assert data["passed"] is False and data["checks"] == {"one": True, "two": False}
    assert (tmp_path / "run.log").read_text(encoding="utf-8").count("\n") == 2
    with pytest.raises(e2e_log.RefusedLineError):
        rec.log("typed", "ok", PASSWORD)


# --- log collector -----------------------------------------------------------------------------------------------


def test_sanitize_masks_and_reports() -> None:
    message, kinds = collect_logs.sanitize(f"acct 123456789012 {JWT} pw {PASSWORD}", [PASSWORD])
    assert kinds == ["password", "jwt"]
    assert "123456789012" not in message and PASSWORD not in message and JWT not in message


def test_error_lines_detects_levels() -> None:
    lines = ['{"level": "ERROR", "message": "x"}', '{"level":"INFO"}', "[ERROR] boom", '{"log_level":"ERROR"}']
    assert len(collect_logs.error_lines(lines)) == 3


def test_read_events_follows_pages() -> None:
    class Logs:
        def __init__(self) -> None:
            self.calls: list[dict[str, Any]] = []

        def filter_log_events(self, **kwargs: Any) -> dict[str, Any]:
            self.calls.append(kwargs)
            if "nextToken" not in kwargs:
                return {"events": [{"timestamp": 1}], "nextToken": "t"}
            return {"events": [{"timestamp": 2}]}

    start = datetime(2026, 10, 25, tzinfo=UTC)
    assert len(collect_logs.read_events(Logs(), "g", start, start)) == 2


def test_build_summary_checks(tmp_path: Path) -> None:
    window = (datetime(2026, 10, 25, tzinfo=UTC), datetime(2026, 10, 25, 1, tzinfo=UTC))
    events = [{"timestamp": 0, "message": "ok"}]
    ok = collect_logs.build_summary(events, ["ok"], [], {"a": "OK", "b": "INSUFFICIENT_DATA"}, window, "g")
    assert ok["passed"] is True
    bad = collect_logs.build_summary(
        events, ['{"level":"ERROR"}'], ["jwt"], {"a": "ALARM", "b": "NOT_FOUND"}, window, "g"
    )
    assert bad["passed"] is False and not any(
        bad["checks"][k]
        for k in ("no secrets in logs", "no ERROR lines in the BFF logs", "both alarms exist", "no alarm in ALARM")
    )
    assert collect_logs.build_summary([], [], [], {}, window, "g")["checks"]["BFF logs present"] is False


def test_write_jsonl_sanitizes(tmp_path: Path) -> None:
    path = tmp_path / "x.jsonl"
    messages, found = collect_logs.write_jsonl(
        path, [{"timestamp": 1000, "logStreamName": "s", "message": f"pw {PASSWORD}\n"}], [PASSWORD]
    )
    assert found == ["password"] and PASSWORD not in path.read_text(encoding="utf-8") and messages == ["pw <password>"]


def test_alarm_states_marks_missing() -> None:
    class Cw:
        def describe_alarms(self, AlarmNames: list[str]) -> dict[str, Any]:
            return {"MetricAlarms": [{"AlarmName": "a", "StateValue": "OK"}]}

    assert collect_logs.alarm_states(Cw(), ["a", "b"]) == {"a": "OK", "b": "NOT_FOUND"}


# --- live history redaction and E2E helpers ----------------------------------------------------------------------

FAKE_HEADER_SUBPROTOCOL = "header-eyJob3N0IjoiZXhhbXBsZSIsIkF1dGhvcml6YXRpb24iOiJ0b2tlbiJ9"
FAKE_APPSYNC_REALTIME_URL = "wss://example.appsync-realtime-api.us-east-2.amazonaws.com/event/realtime"
FAKE_APPSYNC_API_URL = "https://example.appsync-api.us-east-2.amazonaws.com/graphql"


def test_redact_sensitive_and_contains_leaked_secret_for_appsync_header_subprotocol() -> None:
    raw = (
        f"subprotocols=['aws-appsync-event-ws', '{FAKE_HEADER_SUBPROTOCOL}'] "
        f"url={FAKE_APPSYNC_REALTIME_URL} graphql={FAKE_APPSYNC_API_URL} "
        f'{{"name":"Sec-WebSocket-Protocol","value":"aws-appsync-event-ws, {FAKE_HEADER_SUBPROTOCOL}"}}'
    )
    assert e2e_redact.contains_leaked_secret(raw) is True
    assert "appsync-header-subprotocol" in e2e_redact.secret_kinds(raw.encode("utf-8"), [])

    redacted = e2e_redact.redact_sensitive(raw)
    assert FAKE_HEADER_SUBPROTOCOL not in redacted
    assert "header-<redacted>" in redacted
    assert "wss://<redacted-appsync-realtime>" in redacted
    assert "https://<redacted-appsync-api>" in redacted
    assert e2e_redact.contains_leaked_secret(redacted) is False
    assert e2e_redact.secret_kinds(redacted.encode("utf-8"), []) == []


def test_console_leaks_and_scan_folder_flag_raw_header_subprotocol(tmp_path: Path) -> None:
    assert web_driver.console_leaks([f"ws {FAKE_HEADER_SUBPROTOCOL}"], []) == ["appsync-header-subprotocol"]
    assert web_driver.console_leaks(["ws header-<redacted>", "header-short"], []) == []

    net_file = tmp_path / "0-trace.network"
    net_file.write_text(f"protocols: {FAKE_HEADER_SUBPROTOCOL}", encoding="utf-8")
    assert e2e_redact.scan_folder(tmp_path, []) == {"0-trace.network": ["appsync-header-subprotocol"]}
    net_file.write_bytes(e2e_redact.redact_bytes(net_file.read_bytes(), []))
    assert e2e_redact.scan_folder(tmp_path, []) == {}


class _FakeLocator:
    def __init__(self, should_fail: bool = False, count_value: int = 0) -> None:
        self.should_fail = should_fail
        self.count_value = count_value
        self.timeouts: list[int] = []

    @property
    def first(self) -> _FakeLocator:
        return self

    def or_(self, other: _FakeLocator) -> _FakeLocator:
        return _FakeLocator(
            should_fail=self.should_fail and other.should_fail,
            count_value=max(self.count_value, other.count_value),
        )

    def wait_for(self, timeout: int = 0) -> None:
        self.timeouts.append(timeout)
        if self.should_fail:
            raise TimeoutError("timed out")

    def count(self) -> int:
        return self.count_value


class _FakeLiveHistoryPage:
    def __init__(
        self,
        missing_texts: set[str] | None = None,
        chip_count: int = 0,
    ) -> None:
        self.missing_texts = missing_texts or set()
        self.chip_count = chip_count
        self.screenshots: list[Path] = []
        self.queried_texts: list[str] = []

    def get_by_text(self, text: str, exact: bool = False) -> _FakeLocator:
        self.queried_texts.append(text)
        return _FakeLocator(should_fail=text in self.missing_texts)

    def get_by_label(self, label: str, exact: bool = False) -> _FakeLocator:
        self.queried_texts.append(label)
        return _FakeLocator(should_fail=label in self.missing_texts)

    def locator(self, selector: str) -> _FakeLocator:
        assert selector == '[aria-label^="Live history status:"]'
        return _FakeLocator(count_value=self.chip_count)

    def screenshot(self, path: Path) -> None:
        self.screenshots.append(path)


def test_live_history_semantics_label() -> None:
    assert web_driver.live_history_semantics_label("Live") == "Live history status: Live"


def test_wait_for_live_history_status_records_connected_and_not_configured(tmp_path: Path) -> None:
    rec = web_driver.Recorder(tmp_path / "ok", [PASSWORD])
    page = _FakeLiveHistoryPage()
    assert web_driver.wait_for_live_history_status(page, rec) is True
    assert rec.checks["live_history_connected"] is True

    rec_unconfigured = web_driver.Recorder(tmp_path / "unconfigured", [PASSWORD])
    missing = {"Live", "Live history status: Live"}
    page_unconfigured = _FakeLiveHistoryPage(missing_texts=missing, chip_count=0)
    assert web_driver.wait_for_live_history_status(page_unconfigured, rec_unconfigured) is False
    assert "live_history_connected" not in rec_unconfigured.checks
    assert rec_unconfigured.informational["live_history_connected"] is False

    rec_failed = web_driver.Recorder(tmp_path / "failed", [PASSWORD])
    page_configured = _FakeLiveHistoryPage(missing_texts=missing, chip_count=1)
    assert web_driver.wait_for_live_history_status(page_configured, rec_failed) is False
    assert rec_failed.checks["live_history_connected"] is False


def test_verify_live_history_auto_updated_checks_rows_and_transport(tmp_path: Path) -> None:
    rec = web_driver.Recorder(tmp_path / "updated", [PASSWORD])
    page = _FakeLiveHistoryPage()
    assert web_driver.verify_live_history_auto_updated(page, rec, tmp_path) is True
    assert rec.checks["live_history_auto_updated"] is True
    assert page.screenshots == [tmp_path / "08-live-history-updated.png"]
    assert web_driver.LIVE_HISTORY_PRODUCT_ROW in page.queried_texts
    assert web_driver.LIVE_HISTORY_DIVIDE_BY_ZERO_ROW in page.queried_texts
    assert web_driver.LIVE_HISTORY_WEBSOCKET_SUBTITLE in page.queried_texts

    rec_missing = web_driver.Recorder(tmp_path / "missing", [PASSWORD])
    page_missing = _FakeLiveHistoryPage(missing_texts={web_driver.LIVE_HISTORY_DIVIDE_BY_ZERO_ROW})
    assert web_driver.verify_live_history_auto_updated(page_missing, rec_missing, tmp_path) is False
    assert rec_missing.checks["live_history_auto_updated"] is False
