"""Tests for the magnitude algorithms.  Python's int is used only as an oracle."""

import random

import pytest

from bigint import limbs
from bigint.limbs import BASE


def to_mag(n: int) -> list[int]:
    return limbs.from_digits(str(n)) if n else []


def to_int(m: list[int]) -> int:
    return int(limbs.to_digits(m))


def rand_num(rng: random.Random, max_digits: int) -> int:
    kind = rng.random()
    digits = rng.randint(1, max_digits)
    if kind < 0.2:  # limb-boundary-heavy values
        return int("9" * digits)
    if kind < 0.3:
        return 10 ** (digits - 1)
    return rng.randrange(10**digits)


@pytest.fixture
def rng() -> random.Random:
    return random.Random(12345)


def test_digits_roundtrip(rng):
    for _ in range(300):
        n = rand_num(rng, 200)
        assert to_int(to_mag(n)) == n
    assert limbs.to_digits([]) == "0"
    assert limbs.to_digits([5, 0, 3]) == "3" + "000000000" + "000000005"


def test_compare_add_sub(rng):
    for _ in range(500):
        a, b = rand_num(rng, 80), rand_num(rng, 80)
        ma, mb = to_mag(a), to_mag(b)
        assert limbs.compare(ma, mb) == (a > b) - (a < b)
        assert to_int(limbs.add(ma, mb)) == a + b
        if a >= b:
            assert to_int(limbs.sub(ma, mb)) == a - b


def test_mul(rng):
    for _ in range(500):
        a, b = rand_num(rng, 150), rand_num(rng, 150)
        assert to_int(limbs.mul(to_mag(a), to_mag(b))) == a * b


def test_mul_all_nines_stresses_carries():
    a = 10**5000 - 1
    assert to_int(limbs.mul(to_mag(a), to_mag(a))) == a * a


def test_mul_with_zero_limbs():
    a = int("1" + "0" * 100 + "1")
    b = int("5" + "0" * 40 + "7" + "0" * 30)
    assert to_int(limbs.mul(to_mag(a), to_mag(b))) == a * b


def test_divmod_random(rng):
    for _ in range(1000):
        u, v = rand_num(rng, 200), rand_num(rng, 100) or 1
        q, r = limbs.divmod_mag(to_mag(u), to_mag(v))
        assert (to_int(q), to_int(r)) == divmod(u, v)


def test_divmod_add_back_cases():
    # Shapes that exercise the rare qhat-too-large correction.
    for k in range(2, 12):
        v = BASE**k // 2 + 1
        for u in (BASE ** (2 * k) - 1, BASE ** (2 * k) // 2, v * (BASE**k - 1)):
            q, r = limbs.divmod_mag(to_mag(u), to_mag(v))
            assert (to_int(q), to_int(r)) == divmod(u, v)


def test_divmod_by_zero():
    with pytest.raises(ZeroDivisionError):
        limbs.divmod_mag([1], [])
