import base64
import hashlib
import json
from typing import Any

import pytest

from auth_bff.adapters.inbound.function_url import FunctionUrlAdapter
from auth_bff.application.ports import RequestRecord
from auth_bff.application.use_cases import Login, Logout, Refresh
from auth_bff.domain.errors import (
    AuthError,
    ChallengeRequiredError,
    IdentityProviderUnavailableError,
    InvalidCredentialsError,
    InvalidRequestError,
    RevocationFailedError,
    SessionExpiredError,
    TooManyAttemptsError,
)
from auth_bff.domain.session import SESSION_LIFETIME_SECONDS, AuthOutcome, CookieAction
from tests.fakes import REFRESH_TOKEN, TOKENS, FakeIdentityProvider

ORIGIN = "https://calculator.example.com"
REQUEST_ID = "req-1"
COOKIE = "__Secure-oecalc-refresh"
SET_ATTRIBUTES = "HttpOnly; Secure; SameSite=Strict; Path=/auth"
LOGIN_BODY = json.dumps({"username": "user@example.com", "password": "pw"})


class FakeUseCase:
    def __init__(self, outcome: AuthOutcome) -> None:
        self.outcome = outcome
        self.calls: list[tuple[Any, ...]] = []

    def execute(self, *args: Any) -> AuthOutcome:
        self.calls.append(args)
        return self.outcome


class RecordingLog:
    def __init__(self) -> None:
        self.records: list[RequestRecord] = []

    def record(self, record: RequestRecord) -> None:
        self.records.append(record)


def _success_login() -> AuthOutcome:
    return AuthOutcome(
        cookie=CookieAction.SET,
        tokens=TOKENS,
        refresh_token=REFRESH_TOKEN,
        cookie_max_age=SESSION_LIFETIME_SECONDS,
    )


def _failure(error: AuthError, cookie: CookieAction = CookieAction.KEEP) -> AuthOutcome:
    return AuthOutcome(cookie=cookie, error=error)


class Harness:
    def __init__(
        self,
        login: AuthOutcome | None = None,
        refresh: AuthOutcome | None = None,
        logout: AuthOutcome | None = None,
    ) -> None:
        self.login = FakeUseCase(login or _success_login())
        self.refresh = FakeUseCase(refresh or AuthOutcome(CookieAction.KEEP, tokens=TOKENS))
        self.logout = FakeUseCase(logout or AuthOutcome(CookieAction.CLEAR))
        self.log = RecordingLog()
        self.adapter = FunctionUrlAdapter(
            self.login, self.refresh, self.logout, self.log, allowed_origin=ORIGIN
        )

    @property
    def reached_use_case(self) -> bool:
        return bool(self.login.calls or self.refresh.calls or self.logout.calls)


def event(
    path: str = "/auth/login",
    method: str = "POST",
    body: str | None = LOGIN_BODY,
    headers: dict[str, str] | None = None,
    cookies: list[str] | None = None,
    base64_encoded: bool = False,
) -> dict[str, Any]:
    base_headers = {
        "origin": ORIGIN,
        "x-requested-with": "XMLHttpRequest",
        "content-type": "application/json",
    }
    result: dict[str, Any] = {
        "rawPath": path,
        "headers": headers if headers is not None else base_headers,
        "requestContext": {"http": {"method": method, "path": path}},
        "isBase64Encoded": base64_encoded,
    }
    if body is not None:
        result["body"] = body
    if cookies is not None:
        result["cookies"] = cookies
    return result


def _headers_without(name: str) -> dict[str, str]:
    headers = {
        "origin": ORIGIN,
        "x-requested-with": "XMLHttpRequest",
        "content-type": "application/json",
    }
    del headers[name]
    return headers


def _error_body(response: dict[str, Any]) -> dict[str, str]:
    body: dict[str, str] = json.loads(response["body"])["error"]
    return body


def test_login_success_returns_tokens_and_exactly_one_cookie() -> None:
    harness = Harness()

    response = harness.adapter.handle(event(), REQUEST_ID)

    assert response["statusCode"] == 200
    assert json.loads(response["body"]) == {
        "id_token": TOKENS.id_token,
        "access_token": TOKENS.access_token,
        "expires_in": TOKENS.expires_in,
    }
    assert response["cookies"] == [f"{COOKIE}={REFRESH_TOKEN}; Max-Age=86400; {SET_ATTRIBUTES}"]
    assert response["headers"] == {"Cache-Control": "no-store", "Content-Type": "application/json"}
    assert harness.login.calls == [("user@example.com", "pw")]


def test_login_accepts_a_base64_body_and_a_content_type_with_parameters() -> None:
    harness = Harness()
    encoded = base64.b64encode(LOGIN_BODY.encode()).decode()
    headers = {
        "Origin": ORIGIN,
        "X-Requested-With": "XMLHttpRequest",
        "Content-Type": "application/json; charset=utf-8",
    }

    response = harness.adapter.handle(
        event(body=encoded, base64_encoded=True, headers=headers), REQUEST_ID
    )

    assert response["statusCode"] == 200


def test_a_request_without_origin_is_accepted() -> None:
    harness = Harness()

    response = harness.adapter.handle(event(headers=_headers_without("origin")), REQUEST_ID)

    assert response["statusCode"] == 200


@pytest.mark.parametrize(
    ("error", "status"),
    [
        (InvalidRequestError(), 400),
        (InvalidCredentialsError(), 401),
        (ChallengeRequiredError(), 409),
        (TooManyAttemptsError(), 429),
        (IdentityProviderUnavailableError(), 503),
    ],
)
def test_login_failures_map_to_status_without_cookie(error: AuthError, status: int) -> None:
    harness = Harness(login=_failure(error))

    response = harness.adapter.handle(event(), REQUEST_ID)

    assert response["statusCode"] == status
    assert "cookies" not in response
    assert _error_body(response)["code"] == error.code
    assert _error_body(response)["request_id"] == REQUEST_ID
    assert response["headers"]["Cache-Control"] == "no-store"


def test_invalid_credentials_message_is_generic() -> None:
    harness = Harness(login=_failure(InvalidCredentialsError("UserNotFoundException")))

    response = harness.adapter.handle(event(), REQUEST_ID)

    assert "UserNotFound" not in response["body"]
    assert _error_body(response)["message"] == "The username or password is incorrect."


def test_refresh_success_sends_no_set_cookie() -> None:
    harness = Harness()

    response = harness.adapter.handle(
        event("/auth/refresh", body=None, cookies=[f"{COOKIE}={REFRESH_TOKEN}"]), REQUEST_ID
    )

    assert response["statusCode"] == 200
    assert "cookies" not in response
    assert harness.refresh.calls == [(REFRESH_TOKEN,)]


def test_refresh_reads_the_cookie_header_when_the_cookies_list_is_absent() -> None:
    harness = Harness()
    headers = {
        "origin": ORIGIN,
        "x-requested-with": "XMLHttpRequest",
        "content-type": "application/json",
        "cookie": f"other=1; {COOKIE}={REFRESH_TOKEN}",
    }

    harness.adapter.handle(event("/auth/refresh", body=None, headers=headers), REQUEST_ID)

    assert harness.refresh.calls == [(REFRESH_TOKEN,)]


def test_refresh_without_a_cookie_passes_none_to_the_use_case() -> None:
    harness = Harness(refresh=_failure(SessionExpiredError(), CookieAction.CLEAR))

    response = harness.adapter.handle(event("/auth/refresh", body=None), REQUEST_ID)

    assert harness.refresh.calls == [(None,)]
    assert response["statusCode"] == 401


def test_refresh_session_expired_answers_401_and_clears_the_cookie() -> None:
    harness = Harness(refresh=_failure(SessionExpiredError(), CookieAction.CLEAR))

    response = harness.adapter.handle(event("/auth/refresh", body=None), REQUEST_ID)

    assert response["statusCode"] == 401
    assert response["cookies"] == [f"{COOKIE}=; Max-Age=0; {SET_ATTRIBUTES}"]


def test_refresh_unavailable_answers_503_and_keeps_the_cookie() -> None:
    harness = Harness(refresh=_failure(IdentityProviderUnavailableError()))

    response = harness.adapter.handle(event("/auth/refresh", body=None), REQUEST_ID)

    assert response["statusCode"] == 503
    assert "cookies" not in response


def test_logout_answers_204_without_body_and_clears_the_cookie() -> None:
    harness = Harness()

    response = harness.adapter.handle(
        event("/auth/logout", body=None, cookies=[f"{COOKIE}={REFRESH_TOKEN}"]), REQUEST_ID
    )

    assert response["statusCode"] == 204
    assert "body" not in response
    assert response["headers"] == {"Cache-Control": "no-store"}
    assert response["cookies"] == [f"{COOKIE}=; Max-Age=0; {SET_ATTRIBUTES}"]
    assert harness.logout.calls == [(REFRESH_TOKEN,)]


def test_logout_revocation_failure_answers_502_and_clears_the_cookie() -> None:
    harness = Harness(logout=_failure(RevocationFailedError(), CookieAction.CLEAR))

    response = harness.adapter.handle(event("/auth/logout", body=None), REQUEST_ID)

    assert response["statusCode"] == 502
    assert response["cookies"] == [f"{COOKIE}=; Max-Age=0; {SET_ATTRIBUTES}"]
    assert _error_body(response)["code"] == "revocation_failed"


oversize_body = json.dumps({"username": "u", "password": "p", "pad": "x" * 4096})

REJECTED_EVENTS = {
    "foreign origin": event(headers={**_headers_without("origin"), "origin": "https://evil.test"}),
    "missing x-requested-with": event(headers=_headers_without("x-requested-with")),
    "empty x-requested-with": event(
        headers={**_headers_without("x-requested-with"), "x-requested-with": ""}
    ),
    "missing content type": event(headers=_headers_without("content-type")),
    "wrong content type": event(
        headers={**_headers_without("content-type"), "content-type": "text/plain"}
    ),
    "oversize body": event(body=oversize_body),
    "oversize base64 body": event(
        body=base64.b64encode(oversize_body.encode()).decode(), base64_encoded=True
    ),
    "invalid base64": event(body="***", base64_encoded=True),
    "bad json": event(body="{not json"),
    "json array": event(body="[]"),
    "missing body": event(body=None),
    "missing password": event(body=json.dumps({"username": "u"})),
    "non string username": event(body=json.dumps({"username": 1, "password": "p"})),
    "too long password": event(body=json.dumps({"username": "u", "password": "p" * 300})),
    "deeply nested json": event(body="[" * 4000),
    "wrong method": event(method="GET"),
    "unknown path": event(path="/auth/other"),
    "trailing slash": event(path="/auth/login/"),
    "root path": event(path="/"),
}


@pytest.mark.parametrize("name", list(REJECTED_EVENTS))
def test_rejected_requests_answer_400_and_never_reach_a_use_case(name: str) -> None:
    harness = Harness()

    response = harness.adapter.handle(REJECTED_EVENTS[name], REQUEST_ID)

    assert response["statusCode"] == 400
    assert _error_body(response) == {
        "code": "invalid_request",
        "message": "The request is not valid.",
        "request_id": REQUEST_ID,
    }
    assert not harness.reached_use_case
    assert "cookies" not in response


def test_no_response_is_ever_403_or_404() -> None:
    harness = Harness()
    events = [*REJECTED_EVENTS.values(), event("/auth/refresh", body=None), event("/auth/logout")]

    statuses = {harness.adapter.handle(item, REQUEST_ID)["statusCode"] for item in events}

    assert statuses.isdisjoint({403, 404})


def test_refresh_and_logout_ignore_the_body_content() -> None:
    harness = Harness()

    refresh = harness.adapter.handle(event("/auth/refresh", body="not json"), REQUEST_ID)
    logout = harness.adapter.handle(event("/auth/logout", body="not json"), REQUEST_ID)

    assert (refresh["statusCode"], logout["statusCode"]) == (200, 204)


def test_a_successful_request_is_logged_without_error_fields() -> None:
    harness = Harness()

    harness.adapter.handle(event("/auth/refresh", body=None), REQUEST_ID)

    assert harness.log.records == [RequestRecord("refresh", 200, "ok", REQUEST_ID)]


def test_a_failed_login_is_logged_with_the_error_type_and_the_username_hash() -> None:
    harness = Harness(login=_failure(InvalidCredentialsError("NotAuthorizedException")))

    harness.adapter.handle(event(), REQUEST_ID)

    expected_hash = hashlib.sha256(b"user@example.com").hexdigest()[:12]
    assert harness.log.records == [
        RequestRecord(
            "login", 401, "invalid_credentials", REQUEST_ID, "NotAuthorizedException", expected_hash
        )
    ]


def test_a_rejected_request_is_logged_as_unknown_without_the_path() -> None:
    harness = Harness()

    harness.adapter.handle(event(path="/auth/other"), REQUEST_ID)

    assert harness.log.records == [RequestRecord("unknown", 400, "invalid_request", REQUEST_ID)]


def _login_body_of_size(size: int) -> str:
    base = json.dumps({"username": "user@example.com", "password": "pw", "pad": ""})
    return json.dumps(
        {"username": "user@example.com", "password": "pw", "pad": "x" * (size - len(base))}
    )


@pytest.mark.parametrize("base64_encoded", [False, True])
def test_a_body_of_exactly_4096_bytes_is_accepted_and_one_more_byte_is_rejected(
    base64_encoded: bool,
) -> None:
    def build(size: int) -> dict[str, Any]:
        body = _login_body_of_size(size)
        assert len(body.encode()) == size
        if base64_encoded:
            body = base64.b64encode(body.encode()).decode()
        return event(body=body, base64_encoded=base64_encoded)

    accepted, rejected = Harness(), Harness()

    assert accepted.adapter.handle(build(4096), REQUEST_ID)["statusCode"] == 200
    assert rejected.adapter.handle(build(4097), REQUEST_ID)["statusCode"] == 400
    assert not rejected.reached_use_case


@pytest.mark.parametrize(
    "body",
    [
        '{"username": "\\ud800", "password": "pw"}',
        '{"username": "user", "password": "\\udfff"}',
        '{"username": "a\\ud83dz", "password": "pw"}',
    ],
)
def test_login_strings_that_cannot_be_encoded_are_rejected_with_400(body: str) -> None:
    harness = Harness()

    response = harness.adapter.handle(event(body=body), REQUEST_ID)

    assert response["statusCode"] == 400
    assert _error_body(response)["code"] == "invalid_request"
    assert not harness.reached_use_case
    assert harness.log.records == [RequestRecord("login", 400, "invalid_request", REQUEST_ID)]


def test_a_valid_non_ascii_login_is_accepted() -> None:
    harness = Harness()

    response = harness.adapter.handle(
        event(body=json.dumps({"username": "usuário@example.com", "password": "ñ"})),
        REQUEST_ID,
    )

    assert response["statusCode"] == 200
    assert harness.login.calls == [("usuário@example.com", "ñ")]


@pytest.mark.parametrize(
    "request_context",
    [None, {}, {"http": None}, {"http": {}}, "text", ["http"], {"http": "POST"}],
)
def test_a_missing_or_malformed_request_context_answers_400(request_context: Any) -> None:
    harness = Harness()
    request = event()
    request["requestContext"] = request_context

    response = harness.adapter.handle(request, REQUEST_ID)

    assert response["statusCode"] == 400
    assert harness.log.records == [RequestRecord("unknown", 400, "invalid_request", REQUEST_ID)]
    assert not harness.reached_use_case


def test_an_event_without_request_context_answers_400() -> None:
    harness = Harness()
    request = event()
    del request["requestContext"]

    assert harness.adapter.handle(request, REQUEST_ID)["statusCode"] == 400


class _BoomError(Exception):
    pass


def test_an_unexpected_exception_answers_a_generic_500_and_logs_one_record() -> None:
    harness = Harness()

    def explode(*_: Any) -> AuthOutcome:
        raise _BoomError("password=pw token=abc secret=def")

    harness.login.execute = explode  # type: ignore[method-assign]

    response = harness.adapter.handle(event(), REQUEST_ID)

    assert response["statusCode"] == 500
    assert _error_body(response) == {
        "code": "internal_error",
        "message": "Something went wrong. Try again shortly.",
        "request_id": REQUEST_ID,
    }
    assert "cookies" not in response
    assert response["headers"]["Cache-Control"] == "no-store"
    for leaked in ("pw", "token=abc", "secret=def", "_BoomError"):
        assert leaked not in response["body"]
    assert harness.log.records == [RequestRecord("login", 500, "internal_error", REQUEST_ID)]


def test_an_unexpected_exception_while_reading_the_event_is_also_a_500() -> None:
    harness = Harness()
    request = event()
    request["headers"] = 5

    response = harness.adapter.handle(request, REQUEST_ID)

    assert response["statusCode"] == 500
    assert harness.log.records == [RequestRecord("login", 500, "internal_error", REQUEST_ID)]


@pytest.mark.parametrize(
    "value", ["abc; Domain=evil.test", "abc\r\nSet-Cookie: x=1", "abc\nx", "a b", "a,b", ""]
)
def test_cookie_values_with_injection_characters_are_never_sent(value: str) -> None:
    harness = Harness(
        login=AuthOutcome(
            cookie=CookieAction.SET,
            tokens=TOKENS,
            refresh_token=value,
            cookie_max_age=SESSION_LIFETIME_SECONDS,
        )
    )

    response = harness.adapter.handle(event(), REQUEST_ID)

    assert response["statusCode"] == 503
    assert "cookies" not in response
    assert TOKENS.id_token not in response["body"]
    assert [record.status for record in harness.log.records] == [503]
    assert harness.log.records[0].error_type == "InvalidCookieValue"


@pytest.mark.parametrize("cookie_value", ["x" * 4097, "ab cd", "a\x00b", "é", 'ab"cd'])
def test_an_oversize_or_malformed_refresh_cookie_answers_401_and_clears_it(
    cookie_value: str,
) -> None:
    provider = FakeIdentityProvider()
    adapter = FunctionUrlAdapter(
        Login(provider), Refresh(provider), Logout(provider), RecordingLog(), allowed_origin=ORIGIN
    )

    response = adapter.handle(
        event("/auth/refresh", body=None, cookies=[f"{COOKIE}={cookie_value}"]), REQUEST_ID
    )

    assert response["statusCode"] == 401
    assert response["cookies"] == [f"{COOKIE}=; Max-Age=0; {SET_ATTRIBUTES}"]
    assert provider.calls == []


def test_a_refresh_cookie_of_exactly_4096_characters_is_passed_on() -> None:
    harness = Harness()

    harness.adapter.handle(
        event("/auth/refresh", body=None, cookies=[f"{COOKIE}={'x' * 4096}"]), REQUEST_ID
    )

    assert harness.refresh.calls == [("x" * 4096,)]
