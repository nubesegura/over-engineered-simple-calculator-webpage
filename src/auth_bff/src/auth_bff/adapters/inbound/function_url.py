"""Lambda function URL entrypoint adapter (payload format 2.0): routing, validation, cookie."""

import base64
import binascii
import hashlib
import json
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

from auth_bff.adapters.inbound.cookies import read_refresh_token, set_cookie_values
from auth_bff.adapters.inbound.responses import (
    Response,
    error_response,
    no_content_response,
    tokens_response,
)
from auth_bff.application.ports import (
    LoginUseCase,
    LogoutUseCase,
    RefreshUseCase,
    RequestLog,
    RequestRecord,
)
from auth_bff.domain.errors import AuthError, InternalError, InvalidRequestError
from auth_bff.domain.session import AuthOutcome, CookieAction

MAX_BODY_BYTES = 4096
MAX_FIELD_LENGTH = 256
_HASH_LENGTH = 12
_UNKNOWN_ENDPOINT = "unknown"
_ROUTES = {"/auth/login": "login", "/auth/refresh": "refresh", "/auth/logout": "logout"}


@dataclass(frozen=True)
class _Request:
    body: bytes
    refresh_token: str | None


@dataclass(frozen=True)
class _Handled:
    outcome: AuthOutcome
    username_hash: str | None = None


def _mapping(value: Any) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _lower_headers(event: Mapping[str, Any]) -> dict[str, str]:
    raw = event.get("headers") or {}
    return {str(name).lower(): str(value) for name, value in raw.items()}


def _cookie_headers(event: Mapping[str, Any], headers: Mapping[str, str]) -> list[str]:
    cookies = [str(cookie) for cookie in event.get("cookies") or []]
    if "cookie" in headers:
        cookies.append(headers["cookie"])
    return cookies


def _decode_body(event: Mapping[str, Any]) -> bytes:
    body = event.get("body") or ""
    if not event.get("isBase64Encoded"):
        return str(body).encode("utf-8")
    try:
        return base64.b64decode(str(body), validate=True)
    except (binascii.Error, ValueError):
        raise InvalidRequestError from None


def _parse_credentials(body: bytes) -> tuple[str, str]:
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, RecursionError):
        raise InvalidRequestError from None
    if not isinstance(data, dict):
        raise InvalidRequestError
    username, password = data.get("username"), data.get("password")
    for value in (username, password):
        if not isinstance(value, str) or len(value) > MAX_FIELD_LENGTH or not _is_encodable(value):
            raise InvalidRequestError
    return str(username), str(password)


def _is_encodable(value: str) -> bool:
    """False for strings with lone surrogates, which a JSON escape such as ud800 can produce."""
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _username_hash(username: str) -> str:
    return hashlib.sha256(username.encode("utf-8")).hexdigest()[:_HASH_LENGTH]


class FunctionUrlAdapter:
    """Turns a function URL event into a use case call and the outcome into a response."""

    def __init__(
        self,
        login: LoginUseCase,
        refresh: RefreshUseCase,
        logout: LogoutUseCase,
        request_log: RequestLog,
        allowed_origin: str,
    ) -> None:
        self._login = login
        self._refresh = refresh
        self._logout = logout
        self._request_log = request_log
        self._allowed_origin = allowed_origin

    def handle(self, event: Mapping[str, Any], request_id: str) -> Response:
        """Answer one request. Any unexpected exception becomes a generic, logged 500."""
        endpoint = _UNKNOWN_ENDPOINT
        try:
            endpoint = self._route(event)
            handled = self._run(endpoint, event)
            handled, response = self._answer(handled, request_id)
            record = self._record(endpoint, response, handled, request_id)
        except Exception:
            response = error_response(InternalError(), request_id, [])
            record = RequestRecord(endpoint, 500, InternalError.code, request_id)
        self._request_log.record(record)
        return response

    def _answer(self, handled: _Handled, request_id: str) -> tuple[_Handled, Response]:
        try:
            return handled, self._respond(handled.outcome, request_id)
        except AuthError as error:
            failed = _Handled(AuthOutcome(cookie=CookieAction.KEEP, error=error))
            return failed, self._respond(failed.outcome, request_id)

    @staticmethod
    def _route(event: Mapping[str, Any]) -> str:
        method = str(_mapping(_mapping(event.get("requestContext")).get("http")).get("method", ""))
        endpoint = _ROUTES.get(str(event.get("rawPath", "")))
        if method.upper() != "POST" or endpoint is None:
            return _UNKNOWN_ENDPOINT
        return endpoint

    def _run(self, endpoint: str, event: Mapping[str, Any]) -> _Handled:
        try:
            if endpoint == _UNKNOWN_ENDPOINT:
                raise InvalidRequestError
            request = self._validate(event)
            return self._dispatch(endpoint, request)
        except InvalidRequestError as error:
            return _Handled(AuthOutcome(cookie=CookieAction.KEEP, error=error))

    def _validate(self, event: Mapping[str, Any]) -> _Request:
        headers = _lower_headers(event)
        origin = headers.get("origin")
        if origin is not None and origin != self._allowed_origin:
            raise InvalidRequestError
        if not headers.get("x-requested-with"):
            raise InvalidRequestError
        media_type = headers.get("content-type", "").split(";")[0].strip().lower()
        if media_type != "application/json":
            raise InvalidRequestError
        body = _decode_body(event)
        if len(body) > MAX_BODY_BYTES:
            raise InvalidRequestError
        return _Request(body, read_refresh_token(_cookie_headers(event, headers)))

    def _dispatch(self, endpoint: str, request: _Request) -> _Handled:
        if endpoint == "login":
            username, password = _parse_credentials(request.body)
            outcome = self._login.execute(username, password)
            return _Handled(outcome, _username_hash(username))
        use_case: Callable[[str | None], AuthOutcome] = (
            self._refresh.execute if endpoint == "refresh" else self._logout.execute
        )
        return _Handled(use_case(request.refresh_token))

    @staticmethod
    def _respond(outcome: AuthOutcome, request_id: str) -> Response:
        cookies = set_cookie_values(outcome)
        if outcome.error is not None:
            return error_response(outcome.error, request_id, cookies)
        if outcome.tokens is None:
            return no_content_response(cookies)
        return tokens_response(outcome.tokens, cookies)

    @staticmethod
    def _record(
        endpoint: str, response: Response, handled: _Handled, request_id: str
    ) -> RequestRecord:
        status = int(response["statusCode"])
        error = handled.outcome.error
        if error is None:
            return RequestRecord(endpoint, status, "ok", request_id)
        return RequestRecord(
            endpoint=endpoint,
            status=status,
            outcome=error.code,
            request_id=request_id,
            error_type=error.provider_error_type,
            username_hash=handled.username_hash if endpoint == "login" else None,
        )
