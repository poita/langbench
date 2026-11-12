import random

import pytest

from oracle import reference
from softfloat import QNAN, add, div, evaluate_line, mul, sqrt, sub

ONE, TWO, THREE = 0x3F800000, 0x40000000, 0x40400000
PZERO, NZERO = 0, 0x80000000
PINF, NINF = 0x7F800000, 0xFF800000
MAXF = 0x7F7FFFFF
TINY = 1


def test_spec_example_one():
    assert add(ONE, ONE) == TWO
    assert sub(ONE, ONE) == PZERO
    assert mul(THREE, 0xC0400000) == 0xC1100000
    assert div(ONE, THREE) == 0x3EAAAAAB
    assert sqrt(TWO) == 0x3FB504F3


@pytest.mark.parametrize(
    "got, want",
    [
        (add(PINF, NINF), QNAN),
        (mul(PINF, PZERO), QNAN),
        (div(PZERO, PZERO), QNAN),
        (div(PINF, PINF), QNAN),
        (sqrt(NZERO), NZERO),
        (sqrt(0xBF800000), QNAN),
        (sqrt(NINF), QNAN),
        (sqrt(PINF), PINF),
        (mul(PZERO, 0xBF800000), NZERO),
        (mul(NZERO, NZERO), PZERO),
        (add(NZERO, NZERO), NZERO),
        (add(NZERO, PZERO), PZERO),
        (sub(NZERO, PZERO), NZERO),
        (sub(NZERO, NZERO), PZERO),
        (add(NZERO, ONE), ONE),
        (div(ONE, NZERO), NINF),
        (div(NZERO, PINF), NZERO),
        (div(ONE, PINF), PZERO),
        (add(0x7FC12345, ONE), QNAN),
        (add(0xFF800001, ONE), QNAN),
        (mul(0x80000001, 0x3F000000), NZERO),
    ],
)
def test_special_values(got, want):
    assert got == want


@pytest.mark.parametrize(
    "got, want",
    [
        (add(MAXF, 0x73000000), PINF),
        (add(MAXF, 0x72FFFFFF), MAXF),
        (div(1, TWO), 0),
        (div(3, TWO), 2),
        (add(ONE, 0x33800000), ONE),
        (add(0x3F800001, 0x33800000), 0x3F800002),
        (add(ONE, 0x33000000), ONE),
        (mul(1, 0x3F000000), 0),
        (mul(0x00800000, 0x3F000000), 0x00400000),
        (sub(0x00800001, 0x00800000), 1),
    ],
)
def test_rounding_edges(got, want):
    assert got == want


def test_evaluate_line():
    assert evaluate_line("div 3f800000 40400000") == "3eaaaaab"
    assert evaluate_line("sqrt 40000000") == "3fb504f3"
    with pytest.raises(ValueError):
        evaluate_line("pow 3f800000 3f800000")
    with pytest.raises(ValueError):
        evaluate_line("sqrt 3f800000 3f800000")


def _interesting(rng):
    kind = rng.randrange(6)
    if kind == 0:
        return rng.getrandbits(32)
    if kind == 1:  # denormal
        return (rng.getrandbits(1) << 31) | rng.getrandbits(rng.randrange(1, 24))
    if kind == 2:  # near 1
        return (rng.getrandbits(1) << 31) | (0x3F800000 + rng.randrange(-40, 40))
    if kind == 3:  # extreme exponents
        e = rng.choice([0, 1, 2, 0xFD, 0xFE, 0xFF, 0x7F, 0x7E, 0x80])
        return (rng.getrandbits(1) << 31) | (e << 23) | rng.choice([0, 1, 0x7FFFFF, rng.getrandbits(23)])
    if kind == 4:  # few significant bits
        return (rng.getrandbits(1) << 31) | (rng.randrange(0, 255) << 23) | (rng.getrandbits(3) << 20)
    return (rng.getrandbits(1) << 31) | (rng.randrange(1, 255) << 23) | rng.getrandbits(23)


@pytest.mark.parametrize("op", ["add", "sub", "mul", "div"])
def test_binary_matches_reference(op):
    fn = {"add": add, "sub": sub, "mul": mul, "div": div}[op]
    rng = random.Random(op)
    for _ in range(20000):
        a, b = _interesting(rng), _interesting(rng)
        assert fn(a, b) == reference(op, a, b), (op, hex(a), hex(b))


def test_sqrt_matches_reference():
    rng = random.Random("sqrt")
    for _ in range(20000):
        a = _interesting(rng)
        assert sqrt(a) == reference("sqrt", a), hex(a)


def test_add_exact_cancellation_and_ties():
    rng = random.Random(7)
    for _ in range(5000):
        a = rng.getrandbits(31)
        assert sub(a, a) == 0 or a >= 0x7F800000
        b = (a & 0x7F800000) | rng.getrandbits(23)
        assert add(a, b ^ 0x80000000) == reference("add", a, b ^ 0x80000000)
