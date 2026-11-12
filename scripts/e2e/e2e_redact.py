"""Secret handling for the files of an end-to-end run: redact, then scan.

Playwright records what is typed and every request in its trace, so the trace is redacted after the run (test-user
password, JWTs, cookie and authorization header values) and the whole run folder is scanned again afterwards.
The summary only says which kinds of secret were found and in which file; it never prints a value.
"""

from __future__ import annotations

import re
import shutil
import zipfile
from pathlib import Path

JWT = re.compile(rb"eyJ[\w-]{10,}\.[\w-]+\.[\w-]*")
ACCOUNT_ID = re.compile(rb"(?<![\w.-])\d{12}(?![\w.-])")
# Header objects in a Playwright trace: {"name":"Set-Cookie","value":"..."} or Sec-WebSocket-Protocol
SECRET_HEADER = re.compile(
    rb'("name":"(?:[Ss]et-)?[Cc]ookie"|"name":"[Aa]uthorization"|"name":"[Ss]ec-[Ww]eb[Ss]ocket-[Pp]rotocol")'
    rb'(,"value":")[^"]*(")'
)
COOKIE_PAIR = re.compile(rb"(?i)((?:refresh|id|access)[\w-]*token=)[^;\s\"]+")
# A parameter named exactly `token` in a URL query (after ?, & or ;, JSON-escaped ampersand, `%3D` for the equals).
# `csrf_token=`, `next_page_token=` or `foo.token=` do not match: the name must follow the query delimiter.
_TOKEN_PARAM = rb"((?:[?&;]|\\u0026)token(?:=|%3[dD]))"
TOKEN_QUERY = re.compile(rb"(?i)" + _TOKEN_PARAM + rb"(?!<redacted>)")
TOKEN_VALUE = re.compile(rb"(?i)" + _TOKEN_PARAM + rb"[^&;\s\"'\\]+")
# AppSync Events WebSocket auth subprotocol: `header-<base64url({host, Authorization})>`.
HEADER_SUBPROTOCOL = re.compile(rb"(?<![\w-])header-(?!<redacted>)[A-Za-z0-9_-]{20,}")
# AppSync Events real-time WebSocket and GraphQL HTTPS endpoint URLs.
APPSYNC_REALTIME_URL = re.compile(rb"wss?://[A-Za-z0-9.-]*\.appsync-realtime-api\.[A-Za-z0-9.-]+(?:/[^\s\"'<>\\]*)?")
APPSYNC_API_URL = re.compile(rb"https?://[A-Za-z0-9.-]*\.appsync-api\.[A-Za-z0-9.-]+(?:/[^\s\"'<>\\]*)?")
# AI Assistant custom domain and regional API Gateway endpoint URLs.
AI_API_URL = re.compile(rb"(?i)https?://ai\.over-engineered-simple-calculator\.[A-Za-z0-9.-]+(?:/[^\s\"'<>\\]*)?")
AI_EXECUTE_API_URL = re.compile(rb"(?i)https?://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com(?:/[^\s\"'<>\\]*)?")
RESOURCES_PREFIX = "resources/"
TEXT_SUFFIXES = {".log", ".json", ".jsonl", ".txt", ".trace", ".network", ".md"}
PLACEHOLDER = b"<redacted>"
HEADER_PLACEHOLDER = b"header-<redacted>"
APPSYNC_REALTIME_PLACEHOLDER = b"wss://<redacted-appsync-realtime>"
APPSYNC_API_PLACEHOLDER = b"https://<redacted-appsync-api>"
AI_API_PLACEHOLDER = b"https://<redacted-ai-api>"


def redact_bytes(data: bytes, passwords: list[str]) -> bytes:
    """Mask passwords, JWTs, headers, token cookies, `token=` query values and AppSync `header-` subprotocols."""
    for password in passwords:
        if password:
            data = data.replace(password.encode("utf-8"), b"<password>")
    data = JWT.sub(b"<jwt>", data)
    data = HEADER_SUBPROTOCOL.sub(HEADER_PLACEHOLDER, data)
    data = APPSYNC_REALTIME_URL.sub(APPSYNC_REALTIME_PLACEHOLDER, data)
    data = APPSYNC_API_URL.sub(APPSYNC_API_PLACEHOLDER, data)
    data = AI_API_URL.sub(AI_API_PLACEHOLDER, data)
    data = AI_EXECUTE_API_URL.sub(AI_API_PLACEHOLDER, data)
    return TOKEN_VALUE.sub(rb"\1" + PLACEHOLDER, _mask_credentials(data))


def redact_sensitive(text: str, passwords: list[str] | None = None) -> str:
    """String helper around `redact_bytes` for console lines, URLs and diagnostic messages."""
    return redact_bytes(text.encode("utf-8"), passwords or []).decode("utf-8", errors="replace")


def _mask_credentials(data: bytes) -> bytes:
    data = SECRET_HEADER.sub(rb"\1\2" + PLACEHOLDER + rb"\3", data)
    return COOKIE_PAIR.sub(rb"\1" + PLACEHOLDER, data)


def redact_trace(trace_zip: Path, passwords: list[str]) -> None:
    """Rewrite the trace zip with every member redacted."""
    temp = trace_zip.with_suffix(".redacting")
    with zipfile.ZipFile(trace_zip) as source, zipfile.ZipFile(temp, "w", zipfile.ZIP_DEFLATED) as target:
        for member in source.infolist():
            target.writestr(member.filename, redact_bytes(source.read(member), passwords))
    shutil.move(temp, trace_zip)


def secret_kinds(data: bytes, passwords: list[str]) -> list[str]:
    """Kinds of secret present in the data (names only)."""
    kinds = []
    if any(password and password.encode("utf-8") in data for password in passwords):
        kinds.append("password")
    if JWT.search(data):
        kinds.append("jwt")
    if TOKEN_QUERY.search(data):
        kinds.append("token-query")
    if HEADER_SUBPROTOCOL.search(data):
        kinds.append("appsync-header-subprotocol")
    jwt_masked = HEADER_SUBPROTOCOL.sub(HEADER_PLACEHOLDER, JWT.sub(b"<jwt>", data))
    if _mask_credentials(jwt_masked) != jwt_masked:
        kinds.append("cookie-or-authorization-header")
    return kinds


def contains_leaked_secret(text: str, passwords: list[str] | None = None) -> bool:
    """True when `text` still carries an unredacted password, JWT, `token=`, auth header or `header-` subprotocol."""
    return bool(secret_kinds(text.encode("utf-8"), passwords or []))


def _members(path: Path) -> list[tuple[str, bytes]]:
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as archive:
            return [
                (f"{path.name}!{info.filename}", archive.read(info))
                for info in archive.infolist()
                if not info.filename.startswith(RESOURCES_PREFIX)
            ]
    if path.suffix in TEXT_SUFFIXES:
        return [(path.name, path.read_bytes())]
    return []


def scan_folder(folder: Path, passwords: list[str]) -> dict[str, list[str]]:
    """Map file (or zip member) -> kinds of secret found, for every text file and zip under the folder."""
    found: dict[str, list[str]] = {}
    for path in sorted(folder.rglob("*")):
        if not path.is_file():
            continue
        for name, data in _members(path):
            kinds = secret_kinds(data, passwords)
            if kinds:
                found[name] = kinds
    return found
