import base64
import hashlib
import hmac as std_hmac
import os
import random

import pytest

from webhooks import (
    Base64Error, b64decode, b64encode, b64urlencode, hmac_sha256, sha256,
)


def test_sha256_vectors():
    assert sha256(b"").hex() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert sha256(b"abc").hex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


@pytest.mark.parametrize("n", list(range(0, 200)) + [1000, 4095, 4096])
def test_sha256_matches_stdlib(n):
    data = bytes(random.Random(n).randrange(256) for _ in range(n))
    assert sha256(data) == hashlib.sha256(data).digest()


def test_hmac_rfc4231_case1():
    assert hmac_sha256(b"\x0b" * 20, b"Hi There").hex() == (
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    )


@pytest.mark.parametrize("keylen", [0, 1, 63, 64, 65, 131, 200])
def test_hmac_matches_stdlib(keylen):
    key = os.urandom(keylen)
    msg = os.urandom(100)
    assert hmac_sha256(key, msg) == std_hmac.new(key, msg, hashlib.sha256).digest()


@pytest.mark.parametrize(
    "data,std,url",
    [
        (b"", "", ""),
        (b"f", "Zg==", "Zg"),
        (b"fo", "Zm8=", "Zm8"),
        (b"foo", "Zm9v", "Zm9v"),
        (b"\xfb\xff", "+/8=", "-_8"),
    ],
)
def test_base64_encode(data, std, url):
    assert b64encode(data) == std
    assert b64urlencode(data) == url


@pytest.mark.parametrize("n", range(0, 40))
def test_base64_roundtrip_matches_stdlib(n):
    data = os.urandom(n)
    assert b64encode(data) == base64.b64encode(data).decode()
    assert b64urlencode(data) == base64.urlsafe_b64encode(data).decode().rstrip("=")
    assert b64decode(b64encode(data)) == data
    assert b64decode(b64urlencode(data)) == data


@pytest.mark.parametrize(
    "text,expected",
    [
        ("", b""),
        ("QQ==", b"A"),
        ("QR==", b"A"),
        ("QQ", b"A"),
        ("+/8=", b"\xfb\xff"),
        ("-_8", b"\xfb\xff"),
    ],
)
def test_base64_decode_valid(text, expected):
    assert b64decode(text) == expected


@pytest.mark.parametrize(
    "text",
    ["Q", "QQ=", "QQ===", "QUJD=", "====", "=QQ", "Q=Q=", "QQ Q", "QQ\n", "+-", "/_", "QQ=\n", "é", "A"],
)
def test_base64_decode_invalid(text):
    with pytest.raises(Base64Error):
        b64decode(text)
