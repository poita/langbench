"""Checks the hand-written bignum arithmetic against Python's ``int``.

Python's unbounded integers are used here only as a test oracle.
"""

import random

import pytest

from scheme_interp import bignum
from scheme_interp.bignum import BigInt


def to_py(x):
    if type(x) is int:
        return x
    v = 0
    for limb in reversed(x.mag):
        v = (v << 30) | limb
    return -v if x.neg else v


def from_py(n):
    return bignum.parse(str(n))


def check_canonical(x):
    if type(x) is BigInt:
        assert abs(to_py(x)) >= bignum.SMALL_LIMIT
        assert x.mag[-1] != 0
    else:
        assert abs(x) < bignum.SMALL_LIMIT


INTERESTING = [
    0, 1, -1, 2**30 - 1, 2**30, 2**31, 2**60, 2**62 - 1, 2**62, -(2**62),
    -(2**62) + 1, 2**63, 2**64 + 1, 2**90, 2**90 - 1, 10**18, 10**19, -(10**40),
]  # fmt: skip


def random_value(rng):
    bits = rng.choice([1, 8, 30, 31, 60, 62, 63, 64, 90, 200, 400, 1000])
    v = rng.getrandbits(bits)
    if rng.random() < 0.2:
        v = (1 << bits) - 1 - v % 3  # near powers of two: stresses Algorithm D
    return -v if rng.random() < 0.5 else v


@pytest.fixture(scope="module")
def samples():
    rng = random.Random(12345)
    return INTERESTING + [random_value(rng) for _ in range(150)]


def test_parse_and_to_string_roundtrip(samples):
    for n in samples:
        x = from_py(n)
        check_canonical(x)
        assert to_py(x) == n
        assert bignum.to_string(x) == str(n)


def test_add_sub_mul_compare(samples):
    vals = [from_py(n) for n in samples]
    for a, na in zip(vals, samples):
        for b, nb in list(zip(vals, samples))[::7]:
            for got, want in (
                (bignum.add(a, b), na + nb),
                (bignum.sub(a, b), na - nb),
                (bignum.mul(a, b), na * nb),
            ):
                check_canonical(got)
                assert to_py(got) == want
            assert bignum.compare(a, b) == (na > nb) - (na < nb)
        assert to_py(bignum.neg(a)) == -na


def test_division_truncates_toward_zero():
    rng = random.Random(99)
    pairs = [(a, b) for a in INTERESTING for b in INTERESTING if b]
    pairs += [(random_value(rng), random_value(rng) or 1) for _ in range(3000)]
    for na, nb in pairs:
        q, r = bignum.divmod_trunc(from_py(na), from_py(nb))
        check_canonical(q)
        check_canonical(r)
        wq = abs(na) // abs(nb) * (1 if (na < 0) == (nb < 0) else -1)
        assert to_py(q) == wq, (na, nb)
        assert to_py(r) == na - nb * wq, (na, nb)


def test_big_factorial_digits():
    acc = 1
    py = 1
    for i in range(1, 400):
        acc = bignum.mul(acc, i)
        py *= i
    assert bignum.to_string(acc) == str(py)
    assert len(bignum.to_string(acc)) == 867


def test_algorithm_d_add_back_case():
    # Classic divisor/dividend pair that triggers the rare "add back" step.
    u = (2**30) ** 3 - 1
    v = (2**30) ** 2 // 2 + 1
    q, r = bignum.divmod_trunc(from_py(u * 7 + 5), from_py(v))
    assert (to_py(q), to_py(r)) == divmod(u * 7 + 5, v)
