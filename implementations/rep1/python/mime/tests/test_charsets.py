import itertools
import random

import pytest

from mimedump.charsets import decode, decode_utf8, decode_utf8_lenient, normalize_charset


def test_normalize():
    assert normalize_charset("  UTF-8\t") == "utf-8"


@pytest.mark.parametrize("name", ["us-ascii", "ASCII", "iso-ir-6", "ANSI_X3.4-1968", "iso646-us"])
def test_ascii_replaces_high_bytes(name):
    assert decode(b"a\x80b\xff", name) == "a�b�"


@pytest.mark.parametrize("name", ["latin1", "ISO-8859-1", "l1", "8859-1", "iso_8859-1"])
def test_latin1(name):
    assert decode(b"\x80\xe9", name) == "\x80\xe9"


@pytest.mark.parametrize("name", ["windows-1252", "cp1252", "ansi", "", "koi8-r", "shift_jis"])
def test_cp1252_and_fallback(name):
    assert decode(b"\x80\x92\x81\xe9\x9f", name) == "€’\x81\xe9Ÿ"


def test_utf8_examples():
    assert decode(b"\xe2\x28\xa1", "utf-8") == "�(�"
    assert decode(b"\xf0\x9f", "utf8") == "�"
    assert decode("é😀".encode(), "unicode-1-1-utf-8") == "é😀"


def test_utf8_lenient_matches_python_replacement_exhaustively():
    interesting = [0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2,
                   0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF]
    for n in (1, 2, 3, 4):
        for seq in itertools.product(interesting, repeat=n):
            data = bytes(seq)
            assert decode_utf8_lenient(data) == data.decode("utf-8", "replace"), data


def test_utf8_lenient_random():
    rng = random.Random(1)
    for _ in range(500):
        data = bytes(rng.choice([0x41, 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x80, 0xED, 0xA0])
                     for _ in range(rng.randint(0, 30)))
        assert decode_utf8(data) == data.decode("utf-8", "replace")
