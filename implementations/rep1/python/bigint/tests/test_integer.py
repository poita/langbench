import random

import pytest

from bigint import BigInt


def B(s):
    return BigInt.parse(s)


@pytest.mark.parametrize(
    "text,canonical",
    [("0", "0"), ("-0", "0"), ("-000", "0"), ("007", "7"), ("-000123", "-123"), ("42", "42")],
)
def test_parse_canonicalises(text, canonical):
    assert str(B(text)) == canonical


@pytest.mark.parametrize("bad", ["", "-", "+5", "1.5", "1e3", " 1", "1 ", "--1", "abc"])
def test_parse_rejects(bad):
    with pytest.raises(ValueError):
        B(bad)


def test_from_int_limits():
    assert str(BigInt.from_int(-123456789012)) == "-123456789012"
    assert str(BigInt.from_int(0)) == "0"
    with pytest.raises(OverflowError):
        BigInt.from_int(1 << 70)


def test_no_negative_zero():
    assert str(B("-5") * B("0")) == "0"
    assert str(B("-7").remainder(B("7"))) == "0"
    assert str(B("-1").quotient(B("2"))) == "0"
    assert str(B("-0") + B("0")) == "0"
    assert str(-B("0")) == "0"
    assert B("-0") == B("0")
    assert B("-0").sign == 0


@pytest.mark.parametrize(
    "a,b,q,r",
    [
        (7, 2, 3, 1),
        (-7, 2, -3, -1),
        (7, -2, -3, 1),
        (-7, -2, 3, -1),
        (-1, 3, 0, -1),
        (0, 5, 0, 0),
    ],
)
def test_truncating_division(a, b, q, r):
    quo, rem = BigInt.from_int(a).divmod_trunc(BigInt.from_int(b))
    assert (str(quo), str(rem)) == (str(q), str(r))


def test_division_by_zero():
    for a in ("5", "0", "-3"):
        with pytest.raises(ZeroDivisionError):
            B(a).divmod_trunc(B("-0"))


def test_compare():
    assert B("007").compare(B("7")) == 0
    assert B("-3").compare(B("-2")) == -1
    assert B("-1").compare(B("0")) == -1
    assert B("10000000000").compare(B("9999999999")) == 1
    assert B("-10000000000").compare(B("-9999999999")) == -1
    assert B("1") < B("2") <= B("2") < B("3")
    assert B("3") > B("-3") >= B("-3")
    assert len({B("1"), B("01"), B("2")}) == 2
    with pytest.raises(TypeError):
        B("1") < 2


def test_pow():
    assert str(B("-2") ** B("3")) == "-8"
    assert str(B("-2") ** 2) == "4"
    assert str(B("-1") ** B("999")) == "-1"
    assert str(B("0") ** B("0")) == "1"
    assert str(B("0") ** B("5")) == "0"
    assert str(B("5") ** B("-0")) == "1"
    assert str(B("-0") ** B("-00")) == "1"
    assert str(B("2") ** B("0100")) == str(2**100)
    with pytest.raises(ValueError):
        B("2") ** B("-1")


def test_pow_huge_exponent_trivial_bases():
    huge = B("1" + "0" * 40 + "1")
    assert str(B("1") ** huge) == "1"
    assert str(B("-1") ** huge) == "-1"
    assert str(B("0") ** huge) == "0"
    with pytest.raises(OverflowError):
        B("2") ** huge


def test_random_against_python_ints():
    rng = random.Random(1234)
    for _ in range(500):
        x = rng.getrandbits(rng.randrange(1, 300)) * rng.choice((-1, 1))
        y = rng.getrandbits(rng.randrange(1, 300)) * rng.choice((-1, 1))
        a, b = B(str(x)), B(str(y))
        assert str(a + b) == str(x + y)
        assert str(a - b) == str(x - y)
        assert str(a * b) == str(x * y)
        assert a.compare(b) == (x > y) - (x < y)
        if y:
            q = abs(x) // abs(y) * (1 if (x < 0) == (y < 0) else -1)
            assert str(a.quotient(b)) == str(q)
            assert str(a.remainder(b)) == str(x - q * y)
