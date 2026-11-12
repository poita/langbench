import os
import random
import zlib

import pytest

from gitrepo.errors import CorruptObjectError
from gitrepo.inflate import adler32, inflate, zlib_decompress


def raw_deflate(data, level=6, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return c.compress(data) + c.flush()


SAMPLES = [
    b"",
    b"a",
    b"hello hello hello hello",
    b"abc" * 5000,
    bytes(range(256)) * 20,
    os.urandom(3000),
    b"".join(random.Random(1).choice([b"foo", b"bar ", b"\n", b"quux"]) for _ in range(20000)),
]


@pytest.mark.parametrize("level", [0, 1, 6, 9])
@pytest.mark.parametrize("i", range(len(SAMPLES)))
def test_roundtrip(i, level):
    data = SAMPLES[i]
    assert inflate(raw_deflate(data, level), 0)[0] == data


@pytest.mark.parametrize("strategy", [zlib.Z_FIXED, zlib.Z_HUFFMAN_ONLY, zlib.Z_RLE])
def test_strategies(strategy):
    data = SAMPLES[6]
    assert inflate(raw_deflate(data, 6, strategy))[0] == data


def test_zlib_wrapper_reports_end():
    a, b = b"first" * 100, b"second" * 100
    blob = b"xx" + zlib.compress(a) + zlib.compress(b)
    out, end = zlib_decompress(blob, 2)
    assert out == a
    assert end == 2 + len(zlib.compress(a))
    assert zlib_decompress(blob, end)[0] == b


def test_adler32_matches_zlib():
    data = os.urandom(10000)
    assert adler32(data) == zlib.adler32(data)


@pytest.mark.parametrize("blob", [
    b"",
    b"\x78",
    b"\x79\x9c",            # bad header checksum / method
    b"\x78\x20\x00",        # preset dictionary
])
def test_bad_headers(blob):
    with pytest.raises(CorruptObjectError):
        zlib_decompress(blob)


def test_truncated_and_corrupt():
    good = zlib.compress(b"some reasonably long text " * 50)
    with pytest.raises(CorruptObjectError):
        zlib_decompress(good[:-6])
    bad = bytearray(good)
    bad[-1] ^= 0xFF
    with pytest.raises(CorruptObjectError):
        zlib_decompress(bytes(bad))
    with pytest.raises(CorruptObjectError):
        inflate(b"\x07")  # block type 3


def test_stored_block_length_mismatch():
    with pytest.raises(CorruptObjectError):
        inflate(b"\x01\x05\x00\x00\x00hello")
