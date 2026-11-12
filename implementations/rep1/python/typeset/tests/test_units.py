import pytest

from typeset.units import alpha, distribute, parse_integer, parse_length, roman, scale


def test_scale_floors():
    assert scale(1054, 10000) == 10540
    assert scale(-60, 1500) == -90
    assert scale(-1, 500) == -1  # floor, not truncation


@pytest.mark.parametrize("text,expected", [
    ("2.5pt", 2500), ("0.5pt", 500), ("1.5mm", 4252), ("-6pt", -6000), ("734", 734),
    ("1in", 72000), ("2pc", 24000), ("3cm", 85050), ("1.125pt", 1125),
])
def test_parse_length_valid(text, expected):
    assert parse_length(text) == expected


@pytest.mark.parametrize("text", ["", "+1pt", "1.2345pt", ".5pt", "5.pt", "20px", "1 pt", "1pt "])
def test_parse_length_invalid(text):
    assert parse_length(text) is None


def test_parse_integer():
    assert parse_integer("-12") == -12
    assert parse_integer("+1") is None
    assert parse_integer("1.0") is None


def test_roman_and_alpha():
    assert [roman(n) for n in (1, 4, 9, 14, 40, 2026)] == ["i", "iv", "ix", "xiv", "xl", "mmxxvi"]
    assert roman(4000) == "mmmm" and roman(5001) == "mmmmmi"
    assert [alpha(n) for n in (1, 26, 27, 28, 52, 53)] == ["a", "z", "aa", "ab", "az", "ba"]


def test_distribute_matches_spec_example():
    assert distribute(-3890, [850] * 6) == [-649, -648, -648, -649, -648, -648]
