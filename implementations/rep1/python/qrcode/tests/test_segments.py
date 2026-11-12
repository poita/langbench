import pytest

from qrcode.segments import (
    Mode, choose_version, data_bit_length, encode_segment, select_mode, to_codewords,
)
from qrcode.tables import ErrorCorrection, data_codewords


@pytest.mark.parametrize(
    "text, mode",
    [
        (b"0123", Mode.NUMERIC),
        (b"HELLO WORLD", Mode.ALPHANUMERIC),
        (b"A-1 $%*+./:", Mode.ALPHANUMERIC),
        (b"hello", Mode.BYTE),
        ("é".encode(), Mode.BYTE),
        (b"12a", Mode.BYTE),
    ],
)
def test_select_mode(text, mode):
    assert select_mode(text) is mode


def test_bit_lengths():
    assert [data_bit_length(Mode.NUMERIC, n) for n in (1, 2, 3, 4)] == [4, 7, 10, 14]
    assert data_bit_length(Mode.ALPHANUMERIC, 3) == 17
    assert data_bit_length(Mode.BYTE, 5) == 40


def test_count_widths():
    assert [Mode.NUMERIC.count_bits(v) for v in (1, 9, 10, 26, 27, 40)] == [10, 10, 12, 12, 14, 14]
    assert [Mode.BYTE.count_bits(v) for v in (1, 9, 10, 40)] == [8, 8, 16, 16]
    assert [Mode.ALPHANUMERIC.count_bits(v) for v in (9, 10, 27)] == [9, 11, 13]


def test_numeric_segment():
    value, nbits = encode_segment(b"01234567", Mode.NUMERIC, 1)
    assert nbits == 4 + 10 + 27
    assert format(value, f"0{nbits}b") == "0001" + "0000001000" + "0000001100" + "0101011001" + "1000011"


def test_alnum_segment():
    value, nbits = encode_segment(b"AC-", Mode.ALPHANUMERIC, 1)
    assert nbits == 4 + 9 + 11 + 6
    assert format(value, f"0{nbits}b").endswith(format(45 * 10 + 12, "011b") + format(41, "06b"))


def test_hello_world_data_codewords():
    value, nbits = encode_segment(b"HELLO WORLD", Mode.ALPHANUMERIC, 1)
    cw = to_codewords(value, nbits, 16)
    assert list(cw) == [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]


def test_choose_version_boundaries():
    cap = lambda ecl: (lambda v: data_codewords(v, ecl))
    L = ErrorCorrection.L
    assert choose_version(Mode.BYTE, 17, cap(L)) == 1
    assert choose_version(Mode.BYTE, 18, cap(L)) == 2
    assert choose_version(Mode.NUMERIC, 7089, cap(L)) == 40
    assert choose_version(Mode.NUMERIC, 7090, cap(L)) is None


def test_terminator_truncation():
    # One bit of room left: terminator is truncated to 1 bit.
    cw = to_codewords(0b1, 8 * 9 - 1, 9)
    assert len(cw) == 9
