import os
import random
import zlib

import pytest

from conftest import BitWriter, fixed_lit
from inflate import InflateError, TrailingDataError, TruncatedStreamError, inflate


def deflate(data: bytes, level: int = 6, strategy: int = zlib.Z_DEFAULT_STRATEGY) -> bytes:
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return c.compress(data) + c.flush()


# ---- spec examples ------------------------------------------------------


def test_empty_fixed_block():
    assert inflate(bytes.fromhex("0300")) == b""


def test_stored_block():
    assert inflate(bytes.fromhex("010100feff41")) == b"A"


def test_fixed_block_with_copy():
    assert inflate(bytes.fromhex("4b4c4a862000")) == b"abcabcabc"


def test_copy_before_any_output():
    with pytest.raises(InflateError):
        inflate(bytes.fromhex("030200"))


# ---- round trips against zlib's compressor ------------------------------

SAMPLES = {
    "empty": b"",
    "text": (b"the quick brown fox jumps over the lazy dog. " * 500),
    "zeros": bytes(100_000),
    "random": os.urandom(70_000),
    "mixed": bytes(random.Random(1).choices(b"abcdefgh", k=50_000)),
}


@pytest.mark.parametrize("name", SAMPLES)
@pytest.mark.parametrize("level", [0, 1, 6, 9])
def test_roundtrip_levels(name, level):
    data = SAMPLES[name]
    assert inflate(deflate(data, level)) == data


@pytest.mark.parametrize(
    "strategy",
    [zlib.Z_FILTERED, zlib.Z_HUFFMAN_ONLY, zlib.Z_RLE, zlib.Z_FIXED],
)
def test_roundtrip_strategies(strategy):
    data = SAMPLES["text"] + SAMPLES["mixed"]
    assert inflate(deflate(data, 6, strategy)) == data


def test_accepts_bytearray_and_memoryview():
    stream = deflate(b"hello hello hello")
    assert inflate(bytearray(stream)) == b"hello hello hello"
    assert inflate(memoryview(stream)) == b"hello hello hello"


# ---- hand-built streams -------------------------------------------------


def test_overlapping_copy():
    w = BitWriter().bits(1, 1).bits(1, 2)
    fixed_lit(w, ord("x"))
    fixed_lit(w, 258)  # length 4
    w.code(0, 5)  # distance 1
    fixed_lit(w, 256)
    assert inflate(w.to_bytes()) == b"xxxxx"


def test_backreference_across_blocks():
    w = BitWriter().bits(0, 1).bits(1, 2)
    fixed_lit(w, ord("a"))
    fixed_lit(w, ord("b"))
    fixed_lit(w, 256)
    w.bits(1, 1).bits(1, 2)
    fixed_lit(w, 257)  # length 3
    w.code(1, 5)  # distance 2
    fixed_lit(w, 256)
    assert inflate(w.to_bytes()) == b"ababa"


def test_length_284_extra_31_is_258():
    w = BitWriter().bits(1, 1).bits(1, 2)
    fixed_lit(w, ord("z"))
    fixed_lit(w, 284)
    w.bits(31, 5)
    w.code(0, 5)
    fixed_lit(w, 256)
    assert inflate(w.to_bytes()) == b"z" * 259


def test_stored_with_nonzero_padding_and_zero_length():
    # header bits 1 (final) 00 (stored), then padding bits set to 1s
    stream = bytes([0b11111001, 0, 0, 0xFF, 0xFF])
    assert inflate(stream) == b""


def _dynamic_header(w: BitWriter, cl_lengths: dict[int, int]) -> None:
    order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    w.bits(0, 5).bits(0, 5).bits(15, 4)  # HLIT=257, HDIST=1, HCLEN=19
    for sym in order:
        w.bits(cl_lengths.get(sym, 0), 3)


def test_dynamic_single_eob_code_and_empty_distance():
    w = BitWriter().bits(1, 1).bits(2, 2)
    # code-length code: 18 -> '0', 0 -> '10', 1 -> '11'
    _dynamic_header(w, {18: 1, 0: 2, 1: 2})
    w.code(0, 1).bits(138 - 11, 7)  # 138 zeros
    w.code(0, 1).bits(118 - 11, 7)  # 118 zeros (symbols 0..255 unused)
    w.code(3, 2)  # symbol 256: length 1
    w.code(2, 2)  # distance symbol 0: length 0 (no distance codes)
    w.code(0, 1)  # the only literal/length code: end of block
    assert inflate(w.to_bytes()) == b""


def test_dynamic_two_code_literal_set_and_single_distance_code():
    w = BitWriter().bits(1, 1).bits(2, 2)
    _dynamic_header(w, {18: 1, 0: 2, 1: 2})
    w.code(0, 1).bits(138 - 11, 7)
    w.code(0, 1).bits(117 - 11, 7)  # 117 zeros: symbols 0..254 unused
    w.code(3, 2)  # symbol 255: length 1
    w.code(3, 2)  # symbol 256: length 1 (complete set)
    w.code(3, 2)  # distance symbol 0: length 1 (single code, accepted)
    w.code(0, 1)  # symbol 255 -> literal 0xff
    w.code(1, 1)  # symbol 256 -> end of block
    assert inflate(w.to_bytes()) == b"\xff"


def test_dynamic_incomplete_literal_code_rejected():
    w = BitWriter().bits(1, 1).bits(2, 2)
    _dynamic_header(w, {18: 1, 0: 2, 1: 2})
    w.code(0, 1).bits(138 - 11, 7)
    w.code(0, 1).bits(117 - 11, 7)
    w.code(3, 2)  # symbol 255: length 1
    w.code(2, 2)  # symbol 256: length 0 -> single code, not EOB
    w.code(2, 2)
    with pytest.raises(InflateError):
        inflate(w.to_bytes() + bytes(4))


def test_dynamic_missing_end_of_block_rejected():
    w = BitWriter().bits(1, 1).bits(2, 2)
    _dynamic_header(w, {18: 1, 0: 2, 1: 2})
    w.code(0, 1).bits(138 - 11, 7)
    w.code(0, 1).bits(118 - 11, 7)
    w.code(2, 2)  # symbol 256: length 0
    w.code(2, 2)
    with pytest.raises(InflateError, match="end-of-block"):
        inflate(w.to_bytes() + bytes(4))


# ---- malformed streams --------------------------------------------------


@pytest.mark.parametrize(
    "hexstr, exc",
    [
        ("", TruncatedStreamError),
        ("00", TruncatedStreamError),  # non-final stored block header only
        ("07", InflateError),  # BTYPE 3
        ("010100fe", TruncatedStreamError),
        ("010100feff", TruncatedStreamError),  # missing data byte
        ("010100fdff41", InflateError),  # NLEN mismatch
        ("0300ff", TrailingDataError),
        ("010100feff4100", TrailingDataError),
        ("03", TruncatedStreamError),  # EOB code cut short
    ],
)
def test_malformed(hexstr, exc):
    with pytest.raises(exc):
        inflate(bytes.fromhex(hexstr))


def test_hlit_too_large():
    w = BitWriter().bits(1, 1).bits(2, 2).bits(30, 5).bits(0, 5).bits(0, 4)
    w.bits(0, 12)
    with pytest.raises(InflateError, match="too many"):
        inflate(w.to_bytes() + bytes(8))


def test_invalid_length_symbol_286():
    w = BitWriter().bits(1, 1).bits(1, 2)
    fixed_lit(w, 286)
    w.code(0, 5)
    with pytest.raises(InflateError):
        inflate(w.to_bytes())


def test_invalid_distance_symbol_30():
    w = BitWriter().bits(1, 1).bits(1, 2)
    fixed_lit(w, ord("a"))
    fixed_lit(w, 257)
    w.code(30, 5)
    fixed_lit(w, 256)
    with pytest.raises(InflateError):
        inflate(w.to_bytes())


def test_truncated_real_stream_every_prefix():
    data = b"hello world, hello deflate! " * 20
    stream = deflate(data)
    assert inflate(stream) == data
    for cut in range(len(stream)):
        with pytest.raises(InflateError):
            inflate(stream[:cut])


def test_trailing_byte_on_real_stream():
    stream = deflate(b"abc")
    with pytest.raises(TrailingDataError):
        inflate(stream + b"\x00")
