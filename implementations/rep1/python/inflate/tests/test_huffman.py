import pytest

from inflate.errors import InflateError
from inflate.huffman import build_table, fixed_tables


def lookup(table, bits_value):
    """Look up the symbol for a bit sequence given as a string like '010'."""
    padded = bits_value.ljust(15, "0")
    index = int(padded[: table.root_bits][::-1], 2)
    entry = table.entries[index]
    if entry < 0:
        entry = ~entry
        sub = entry & 15
        rest = padded[table.root_bits : table.root_bits + sub]
        entry = table.entries[(entry >> 4) + int(rest[::-1], 2)]
    return entry >> 4, entry & 15


def test_rfc_example():
    # RFC 1951 3.2.2: lengths (3,3,3,3,3,2,4,4) -> A=010 ... F=00 G=1110 H=1111
    table = build_table([3, 3, 3, 3, 3, 2, 4, 4], 10)
    assert table.complete
    expected = {0: "010", 1: "011", 2: "100", 3: "101", 4: "110", 5: "00", 6: "1110", 7: "1111"}
    for sym, code in expected.items():
        assert lookup(table, code) == (sym, len(code))


def test_oversubscribed():
    with pytest.raises(InflateError):
        build_table([1, 1, 1], 10)


def test_incomplete_and_single_bit():
    table = build_table([1], 10)
    assert not table.complete and table.single_bit
    assert table.entries == [(0 << 4) | 1, 0]
    assert not build_table([2, 2], 10).single_bit
    assert build_table([], 10).used == 0


def test_second_level_tables():
    # Lengths 1..14 once and 15 twice: a complete code with 15-bit codes.
    lengths = [*range(1, 16), 15]
    table = build_table(lengths, 8)
    assert table.complete and table.root_bits == 8
    assert len(table.entries) < 1 << 15
    for sym in range(14):
        assert lookup(table, "1" * sym + "0") == (sym, sym + 1)
    assert lookup(table, "1" * 14 + "0") == (14, 15)
    assert lookup(table, "1" * 15) == (15, 15)


def test_every_code_roundtrips_through_table():
    lengths = [4] * 16
    table = build_table(lengths, 3)
    for sym in range(16):
        assert lookup(table, format(sym, "04b")) == (sym, 4)


def test_fixed_tables_shape():
    lit, dist = fixed_tables()
    assert lit.complete and dist.complete
    assert lookup(lit, "00110000") == (0, 8)
    assert lookup(lit, "0000000") == (256, 7)
    assert lookup(lit, "110010000") == (144, 9)
    assert lookup(dist, "11111") == (31, 5)
