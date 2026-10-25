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
# Header objects in a Playwright trace: {"name":"Set-Cookie","value":"..."}
SECRET_HEADER = re.compile(rb'("name":"(?:[Ss]et-)?[Cc]ookie"|"name":"[Aa]uthorization")(,"value":")[^"]*(")')
COOKIE_PAIR = re.compile(rb"(?i)((?:refresh|id|access)[\w-]*token=)[^;\s\"]+")
TEXT_SUFFIXES = {".log", ".json", ".jsonl", ".txt", ".trace", ".network", ".md"}
PLACEHOLDER = b"<redacted>"


def redact_bytes(data: bytes, passwords: list[str]) -> bytes:
    """Mask passwords, JWTs, cookie/authorization header values and token cookies."""
    for password in passwords:
        if password:
            data = data.replace(password.encode("utf-8"), b"<password>")
    data = JWT.sub(b"<jwt>", data)
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
    if redact_bytes(data, []) != JWT.sub(b"<jwt>", data):
        kinds.append("cookie-or-authorization-header")
    return kinds


def _members(path: Path) -> list[tuple[str, bytes]]:
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as archive:
            return [(f"{path.name}!{info.filename}", archive.read(info)) for info in archive.infolist()]
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
