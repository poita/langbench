"""Tests for the public BigInt type.  Python's int is used only as an oracle."""

import random

import pytest

from bigint import BigInt


def B(n) -> BigInt:
    return BigInt.parse(str(n))


@pytest.mark.parametrize("text", ["0", "7", "-7", "123456789012345678901234567890"])
def test_parse_str_roundtrip(text):
    assert str(BigInt.parse(text)) == text


@pytest.mark.parametrize(
    "text, canon", [("007", "7"), ("-000123", "-123"), ("-0", "0"), ("-000", "0"), ("000", "0")]
)
def test_parse_normalises(text, canon):
    assert str(BigInt.parse(text)) == canon


@pytest.mark.parametrize("text", ["", "-", "+5", "1 2", "1e5", "--1", "1_0", "٣"])
def test_parse_rejects(text):
    with pytest.raises(ValueError):
        BigInt.parse(text)


def test_from_int():
    assert str(BigInt.from_int(-1234567890123)) == "-1234567890123"
    assert BigInt.from_int(0) == BigInt.parse("-0")
    with pytest.raises(ValueError):
        BigInt.from_int(2**63)


def test_never_negative_zero():
    assert str(B(-5) * B(0)) == "0"
    assert str(B(-7).rem_trunc(B(7))) == "0"
    assert str(B(-1).div_trunc(B(2))) == "0"
    assert str(B(-3) + B(3)) == "0"
    assert str(-B(0)) == "0"


def test_compare_and_operators():
    assert B(-3).compare(B(-2)) == -1
    assert BigInt.parse("007").compare(B(7)) == 0
    assert BigInt.parse("-0").compare(B(0)) == 0
    assert B(5) > B(-50) and B(-5) < B(0) and B(2) >= B(2) and B(2) <= B(2)
    assert B(1) != B(2) and hash(BigInt.parse("-0")) == hash(B(0))
    assert abs(B(-4)) == B(4)


@pytest.mark.parametrize("a, b", [(7, 2), (-7, 2), (7, -2), (-7, -2), (-1, 3), (6, 3), (0, 5)])
def test_division_semantics(a, b):
    q, r = B(a).divmod_trunc(B(b))
    eq = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
    assert str(q) == str(eq)
    assert str(r) == str(a - eq * b)
    assert B(a).div_trunc(B(b)) == q and B(a).rem_trunc(B(b)) == r


def test_division_by_zero():
    with pytest.raises(ZeroDivisionError):
        B(0).divmod_trunc(B(0))
    with pytest.raises(ZeroDivisionError):
        B(5).div_trunc(BigInt.parse("-0"))


def test_pow_edge_cases():
    assert str(B(0) ** B(0)) == "1"
    assert str(B(0) ** B(5)) == "0"
    assert str(B(5) ** BigInt.parse("-0")) == "1"
    assert str(B(-2) ** B(3)) == "-8"
    assert str(B(-2) ** B(2)) == "4"
    assert str(B(-1) ** B(999)) == "-1"
    assert str(B(-1) ** B(10**30)) == "1"
    assert str(B(1) ** B(10**30)) == "1"
    assert str(B(0) ** B(10**30)) == "0"
    with pytest.raises(ValueError):
        B(2).pow(B(-1))
    with pytest.raises(OverflowError):
        B(2).pow(B(10**30))


def test_pow_large():
    assert str(B(2) ** B(1000)) == str(2**1000)
    assert str(B(7) ** B(4000)) == str(7**4000)
    assert str(B(10**999 + 3) ** B(31)) == str((10**999 + 3) ** 31)


def test_randomised_against_int_oracle():
    rng = random.Random(7)
    for _ in range(600):
        a = rng.randrange(-(10 ** rng.randint(1, 120)), 10 ** rng.randint(1, 120))
        b = rng.randrange(-(10 ** rng.randint(1, 60)), 10 ** rng.randint(1, 60))
        A, Bb = B(a), B(b)
        assert str(A + Bb) == str(a + b)
        assert str(A - Bb) == str(a - b)
        assert str(A * Bb) == str(a * b)
        assert A.compare(Bb) == (a > b) - (a < b)
        if b:
            q = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
            assert str(A.div_trunc(Bb)) == str(q)
            assert str(A.rem_trunc(Bb)) == str(a - q * b)
