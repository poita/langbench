import random

import pytest

from bigint import magnitude as mag


def m(n: int) -> list[int]:
    """Reference conversion (tests may use Python's own ints as an oracle)."""
    return mag.from_decimal(str(n))


def val(x: list[int]) -> int:
    return int(mag.to_decimal(x))


def test_decimal_roundtrip():
    for s in ["0", "1", "999999999", "1000000000", "123456789012345678901234567890"]:
        assert mag.to_decimal(mag.from_decimal(s)) == s
    assert mag.from_decimal("000") == []
    assert mag.from_decimal("0007") == [7]


def test_limb_layout():
    assert mag.from_decimal("1000000001") == [1, 1]
    assert mag.to_decimal([0, 0, 5]) == "5000000000000000000"


def test_small_conversions():
    assert mag.from_small(0) == []
    assert mag.to_small(mag.from_small(10**18 - 5)) == 10**18 - 5
    with pytest.raises(OverflowError):
        mag.from_small(1 << 63)


@pytest.mark.parametrize("seed", range(5))
def test_add_sub_cmp_random(seed):
    rng = random.Random(seed)
    for _ in range(200):
        x = rng.getrandbits(rng.randrange(1, 400))
        y = rng.getrandbits(rng.randrange(1, 400))
        assert val(mag.add(m(x), m(y))) == x + y
        assert mag.compare(m(x), m(y)) == (x > y) - (x < y)
        if x >= y:
            assert val(mag.sub(m(x), m(y))) == x - y


def test_sub_borrow_chain_and_negative():
    assert mag.sub(m(10**40), m(1)) == m(10**40 - 1)
    with pytest.raises(ValueError):
        mag.sub(m(1), m(2))


@pytest.mark.parametrize("seed", range(5))
def test_mul_random(seed):
    rng = random.Random(seed)
    for _ in range(100):
        x = rng.getrandbits(rng.randrange(1, 1500))
        y = rng.getrandbits(rng.randrange(1, 1500))
        assert val(mag.mul(m(x), m(y))) == x * y


def test_mul_all_nines_worst_case_carry():
    x = 10**500 - 1
    assert val(mag.mul(m(x), m(x))) == x * x
    x = 10**9 * 40 - 1  # forces more than 8 rows between carry passes
    y = 10**900 - 1
    assert val(mag.mul(m(y), m(y))) == y * y


@pytest.mark.parametrize("seed", range(5))
def test_divmod_random(seed):
    rng = random.Random(seed)
    for _ in range(150):
        x = rng.getrandbits(rng.randrange(1, 1500))
        y = rng.getrandbits(rng.randrange(1, 800)) or 1
        q, r = mag.divmod_(m(x), m(y))
        assert (val(q), val(r)) == divmod(x, y)


def test_divmod_hard_quotient_estimates():
    B = mag.BASE
    cases = [
        (B**6 - 1, B**3 - 1),
        (B**5, B**2 + 1),
        ((B**4 - 1) * (B**3 - 1) + B**3 - 2, B**3 - 1),
        (B**4 * (B // 2) , B**3 * (B // 2) + 1),
        (10**100 - 1, 10**50 + 1),
        (B**7 + B**3, B**4 + B**2 - 1),
    ]
    for x, y in cases:
        q, r = mag.divmod_(m(x), m(y))
        assert (val(q), val(r)) == divmod(x, y)


def test_divmod_add_back_path():
    # Randomised search over limb-patterned operands that hit the rare
    # "qhat one too large" correction.
    rng = random.Random(99)
    B = mag.BASE
    pool = [0, 1, 2, B // 2, B - 2, B - 1]
    for _ in range(3000):
        x = sum(rng.choice(pool) * B**i for i in range(rng.randrange(3, 8)))
        y = sum(rng.choice(pool) * B**i for i in range(rng.randrange(2, 5)))
        if y == 0:
            continue
        q, r = mag.divmod_(m(x), m(y))
        assert (val(q), val(r)) == divmod(x, y)


def test_divmod_by_zero():
    with pytest.raises(ZeroDivisionError):
        mag.divmod_(m(5), [])


def test_pow():
    for base in (0, 1, 2, 7, 10**20 + 3):
        for e in (0, 1, 2, 3, 10, 33):
            assert val(mag.pow_(m(base), e)) == base**e
