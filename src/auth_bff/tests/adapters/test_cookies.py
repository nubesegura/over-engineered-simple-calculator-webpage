import pytest

from auth_bff.adapters.inbound.cookies import (
    COOKIE_NAME,
    clear_cookie,
    read_refresh_token,
    set_cookie,
)
from auth_bff.domain.errors import IdentityProviderUnavailableError

ATTRIBUTES = "HttpOnly; Secure; SameSite=Strict; Path=/auth"


def test_set_cookie_has_the_exact_format() -> None:
    expected = f"{COOKIE_NAME}=abc.DEF-1_2=; Max-Age=86400; {ATTRIBUTES}"

    assert set_cookie("abc.DEF-1_2=", 86400) == expected


@pytest.mark.parametrize(
    "value", ["a;b", "a\rb", "a\nb", "a\r\nSet-Cookie: x=1", "a b", "a,b", 'a"b', "", "é"]
)
def test_set_cookie_rejects_values_that_could_inject_attributes_or_headers(value: str) -> None:
    with pytest.raises(IdentityProviderUnavailableError) as caught:
        set_cookie(value, 86400)

    assert caught.value.provider_error_type == "InvalidCookieValue"


def test_clear_cookie_has_the_exact_format() -> None:
    assert clear_cookie() == f"{COOKIE_NAME}=; Max-Age=0; {ATTRIBUTES}"


def test_read_returns_the_value_of_the_cookie() -> None:
    assert read_refresh_token(["a=1", f"b=2; {COOKIE_NAME}=tok.en-1"]) == "tok.en-1"


@pytest.mark.parametrize("value", ["x" * 4097, 'a"b', "a\x00b", "é", "a b"])
def test_read_treats_an_oversize_or_malformed_value_as_absent(value: str) -> None:
    assert read_refresh_token([f"{COOKIE_NAME}={value}"]) is None


def test_read_returns_none_without_the_cookie_or_with_an_empty_value() -> None:
    assert read_refresh_token(["a=1"]) is None
    assert read_refresh_token([f"{COOKIE_NAME}="]) is None
