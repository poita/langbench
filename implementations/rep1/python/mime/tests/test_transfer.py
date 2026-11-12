import base64
import binascii
import random

import pytest

from mimedump.checksum import adler32, adler32_hex
from mimedump.transfer import decode_base64, decode_body, decode_quoted_printable


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (b"a=20b", b"a b"),
        (b"a=\nb", b"ab"),
        (b"a=3Db", b"a=b"),
        (b"a=Zb", b"a=Zb"),
        (b"a=3\n", b"a=3\n"),
        (b"abc=", b"abc"),
        (b"=0D=0A", b"\r\n"),
        (b"x  \ny", b"x  \ny"),
        (b"=e9=E9", b"\xe9\xe9"),
    ],
)
def test_quoted_printable(raw, expected):
    assert decode_quoted_printable(raw) == expected


def test_base64_matches_reference_for_valid_input():
    rng = random.Random(7)
    for n in range(0, 40):
        data = bytes(rng.randrange(256) for _ in range(n))
        assert decode_base64(base64.b64encode(data)) == data
        assert decode_base64(binascii.b2a_base64(data, newline=True)) == data


def test_base64_lenient():
    assert decode_base64(b"QUJD\nREVG") == b"ABCDEF"
    assert decode_base64(b"QQ") == b"A"
    assert decode_base64(b"QUI") == b"AB"
    assert decode_base64(b"QUJDR") == b"ABC"  # lone trailing char dropped
    assert decode_base64(b"Q U=J!D") == b"ABC"
    assert decode_base64(b"") == b""


def test_decode_body_dispatch():
    assert decode_body(b"a=20", "quoted-printable") == b"a "
    assert decode_body(b"QQ==", "base64") == b"A"
    for enc in ("7bit", "8bit", "binary", "x-unknown", ""):
        assert decode_body(b"a=20", enc) == b"a=20"


def test_adler32_matches_zlib():
    import zlib

    assert adler32_hex(b"") == "00000001"
    assert adler32(b"Wikipedia") == 0x11E60398
    rng = random.Random(3)
    for n in (1, 100, 5551, 5552, 5553, 20000):
        data = bytes(rng.randrange(256) for _ in range(n))
        assert adler32(data) == zlib.adler32(data)
    assert adler32(b"\xff" * 100000) == zlib.adler32(b"\xff" * 100000)
