import pytest

from sqlitefile.values import (
    apply_affinity,
    affinity_of,
    compare,
    format_real,
    format_value,
    parse_numeric_constant,
)


@pytest.mark.parametrize(
    "value, text",
    [
        (1.0, "1.0"), (0.1, "0.1"), (-3.25, "-3.25"), (1 / 3, "0.333333333333333"),
        (1e300, "1.0e+300"), (2.5e-10, "2.5e-10"), (1.5e16, "1.5e+16"),
        (1e14, "100000000000000.0"), (1e15, "1.0e+15"), (0.0001, "0.0001"),
        (1e-5, "1.0e-05"), (0.0, "0.0"), (-0.0, "0.0"),
    ],
)  # fmt: skip
def test_format_real(value, text):
    assert format_real(value) == text


def test_format_value():
    assert format_value(None) == "NULL"
    assert format_value(-7) == "-7"
    assert format_value("é") == "é"
    assert format_value(b"") == ""
    assert format_value(b"\x00\xab") == "00AB"


@pytest.mark.parametrize(
    "decl, aff",
    [
        ("INTEGER", "INTEGER"), ("POINT", "INTEGER"), ("FLOATING POINT", "INTEGER"),
        ("STRING", "NUMERIC"), ("INT TEXT", "INTEGER"), ("CHARFLOAT", "TEXT"),
        ("BLOBREAL", "BLOB"), ("", "BLOB"), ("NVARCHAR(160)", "TEXT"),
        ("NUMERIC(10,2)", "NUMERIC"), ("double precision", "REAL"),
    ],
)  # fmt: skip
def test_affinity(decl, aff):
    assert affinity_of(decl) == aff


def test_ordering_across_classes():
    order = [None, -1, 0.5, 1, "", "a", "b", b"", b"\x00"]
    for i, a in enumerate(order):
        for j, b in enumerate(order):
            assert compare(a, b) == (i > j) - (i < j)


def test_large_integers_compare_exactly():
    assert compare(2**63 - 1, 2**63 - 2) == 1
    assert compare(1, 1.0) == 0


@pytest.mark.parametrize(
    "text, expected",
    [
        (".5", 0.5), ("-.5", -0.5), ("5.", 5.0), (" 5 ", 5), ("+5e0", 5.0),
        ("9223372036854775807", 2**63 - 1), ("9223372036854775808", 2.0**63),
        ("", None), ("-", None), ("0x10", None), ("inf", None), ("5 x", None), ("1e", None),
    ],
)  # fmt: skip
def test_numeric_constant(text, expected):
    got = parse_numeric_constant(text)
    assert got == expected and type(got) is type(expected)


def test_apply_affinity():
    assert apply_affinity(5, "TEXT") == "5"
    assert apply_affinity(1.0, "TEXT") == "1.0"
    assert apply_affinity("7", "INTEGER") == 7
    assert apply_affinity("7", "BLOB") == "7"
    assert apply_affinity("x", "NUMERIC") == "x"
    assert apply_affinity(b"7", "INTEGER") == b"7"
