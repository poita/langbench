#!/usr/bin/env python3
"""Generate tests/*.in deterministically and tests/*.out via reference/main.py.

Hand-written edge cases are embedded as literals; generated cases use fixed
seeds. Known published values (100!, 2^1000, fib(1000)) are cross-checked
against independently known facts before being written.
"""
import math
import os
import random
import subprocess
import sys

if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")

OPS = ["+", "-", "*", "/", "%", "^", "cmp"]


def rand_digits(rng, n):
    """Random n-digit number as a string (no leading zero)."""
    if n <= 0:
        return "0"
    return rng.choice("123456789") + "".join(rng.choice("0123456789") for _ in range(n - 1))


def rand_int_str(rng, max_digits, min_digits=1, signed=True):
    n = rng.randint(min_digits, max_digits)
    s = rand_digits(rng, n)
    if signed and rng.random() < 0.5:
        s = "-" + s
    return s


def q(a, op, b):
    return f"{a} {op} {b}"


def random_queries(rng, count, max_digits, ops, pow_max_exp=50, pow_max_base_digits=10):
    lines = []
    for _ in range(count):
        op = rng.choice(ops)
        if op == "^":
            a = rand_int_str(rng, pow_max_base_digits)
            b = str(rng.randint(0, pow_max_exp))
        elif op in "/%":
            a = rand_int_str(rng, max_digits)
            # Divisor usually shorter than the dividend so quotients are nontrivial.
            b = rand_int_str(rng, max(1, rng.randint(1, max_digits)))
            if rng.random() < 0.02:
                b = "0"
        else:
            a = rand_int_str(rng, max_digits)
            b = rand_int_str(rng, max_digits)
        lines.append(q(a, op, b))
    return lines


def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a


def known_values():
    f100 = math.factorial(100)
    f99 = math.factorial(99)
    p2_1000 = 2 ** 1000
    fib1000, fib999, fib998 = fib(1000), fib(999), fib(998)
    # Independent published facts: Project Euler 16/20 digit sums, fib(1000)
    # digit count, and the textbook value of 100!.
    assert sum(map(int, str(p2_1000))) == 1366
    assert sum(map(int, str(f100))) == 648
    assert len(str(fib1000)) == 209
    assert str(f100) == (
        "93326215443944152681699238856266700490715968264381621468592963895217599993229915"
        "608941463976156518286253697920827223758251185210916864000000000000000000000000"
    )
    assert fib1000 == fib999 + fib998
    return [
        q(2, "^", 1000),
        q(f100, "/", f99),
        q(f99, "*", 100),
        q(f100, "%", f99),
        q(f100, "-", f99 * 100),
        q(fib999, "+", fib998),
        q(fib1000, "-", fib999),
        q(fib1000, "cmp", fib999),
        q(fib1000, "/", fib999),
        q(fib1000, "%", fib999),
        q(p2_1000, "%", 1000000007),
        q(p2_1000, "/", 2 ** 999),
        q(2 ** 999, "*", 2),
        q(p2_1000, "cmp", 2 ** 999),
        q(-p2_1000, "/", 3),
        q(-p2_1000, "%", 3),
        q(3, "^", 500),
        q(10, "^", 1000),
        q(-7, "^", 333),
    ]


def handwritten():
    """Returns list of (name, lines)."""
    t = []
    t.append(("single_add", [q(12, "+", 30)]))
    t.append(("zero_forms", [
        q(0, "+", 0), q("-0", "+", 0), q(0, "+", "-0"), q("-0", "+", "-0"),
        q("000", "*", "-0"), q("-0", "cmp", 0), q(0, "cmp", "-000"),
        q(0, "/", 5), q(0, "%", 5), q(0, "/", -5), q(0, "%", -5),
        q(0, "^", 0), q(0, "^", 1), q(0, "^", 100), q("-0", "^", 0), q("-0", "^", 3),
        q(0, "-", 0), q("-0", "-", "-0"), q(0, "*", 0), q(5, "-", 5), q(-5, "-", -5),
        q(-5, "*", 0), q(0, "*", -5), q(-7, "%", 7), q(-1, "/", 2), q(-1, "/", 3), q(-2, "/", 3),
    ]))
    t.append(("minus_one", [
        q(-1, "*", -1), q(-1, "*", 1), q(1, "*", -1), q(-1, "/", 1), q(-1, "/", -1),
        q(-1, "%", 1), q(-1, "%", -1), q(-1, "cmp", 0), q(0, "cmp", -1), q(-1, "cmp", -1),
        q(-1, "+", 1), q(1, "+", -1), q(-1, "-", -1), q(-1, "-", 1), q(1, "-", -1),
        q(-1, "^", 0), q(-1, "^", 1), q(-1, "^", 2), q(-1, "^", 999), q(-1, "^", 1000),
        q(-1, "cmp", -2), q(-2, "cmp", -1), q(1, "cmp", -1), q(-1, "cmp", 1),
    ]))
    t.append(("carries_borrows", [
        q(999, "+", 1), q(1, "+", 999), q("99999999999999999999", "+", 1),
        q("999999999999999999999999999999999999999999", "+", "1"),
        q("1000000000000000000000000000000", "-", 1),
        q("100000000000000000000", "-", "99999999999999999999"),
        q("1", "-", "100000000000000000000"),
        q("4294967295", "+", 1), q("4294967296", "-", 1),
        q("18446744073709551615", "+", 1), q("18446744073709551616", "-", 1),
        q("999999999", "+", 1), q("1000000000", "-", 1),
        q("999999999999999999", "+", 1), q("1000000000000000000", "-", 1),
        q("999999999999999999999999999", "+", "999999999999999999999999999"),
        q("-999999999999999999999999999", "-", "999999999999999999999999999"),
        q("-999999999999999999999999999", "+", "-1"),
        q("9" * 100, "+", 1), q("1" + "0" * 100, "-", 1), q("9" * 100, "*", "9" * 100),
        q("9" * 100, "+", "1" * 100), q("5" * 60, "+", "5" * 60),
    ]))
    t.append(("subtraction_signs", [
        q(5, "-", 7), q(7, "-", 5), q(-5, "-", 7), q(-7, "-", 5), q(7, "-", -5), q(-5, "-", -7),
        q(-7, "-", -5), q(100, "-", 100), q(-100, "-", -100), q(123456789, "-", 123456788),
        q(123456788, "-", 123456789), q("12345678901234567890", "-", "12345678901234567891"),
        q("-12345678901234567890", "+", "12345678901234567891"),
        q("12345678901234567890", "+", "-12345678901234567891"),
        q("10000000000000000000000000000000000000000", "-", "9999999999999999999999999999999999999999"),
        q("-10000000000000000000000000000000000000000", "+", "9999999999999999999999999999999999999999"),
        q("100", "+", "-99"), q("-100", "+", "99"), q("99", "+", "-100"), q("-99", "+", "100"),
    ]))
    t.append(("division_semantics", [
        q(7, "/", 2), q(-7, "/", 2), q(7, "/", -2), q(-7, "/", -2),
        q(7, "%", 2), q(-7, "%", 2), q(7, "%", -2), q(-7, "%", -2),
        q(1, "/", 3), q(-1, "/", 3), q(1, "/", -3), q(-1, "/", -3),
        q(1, "%", 3), q(-1, "%", 3), q(1, "%", -3), q(-1, "%", -3),
        q(5, "/", 5), q(-5, "/", 5), q(4, "/", 5), q(-4, "/", 5), q(6, "/", 5), q(-6, "/", 5),
        q(6, "%", 5), q(-6, "%", 5), q(5, "%", 5), q(-5, "%", 5), q(0, "/", 1), q(0, "%", 1),
        q(100, "/", 1), q(-100, "/", 1), q(100, "/", -1), q(-100, "/", -1), q(100, "%", -1),
        q(-100, "%", -1), q("123456789012345678901234567890", "/", "1000000000"),
        q("-123456789012345678901234567890", "/", "1000000000"),
        q("123456789012345678901234567890", "%", "1000000000"),
        q("-123456789012345678901234567890", "%", "1000000000"),
        q("-123456789012345678901234567890", "%", "-1000000000"),
        q("123456789012345678901234567890", "/", "12345678901234567890"),
        q("123456789012345678901234567890", "%", "12345678901234567890"),
        q("1", "/", "123456789012345678901234567890"), q("-1", "%", "123456789012345678901234567890"),
        q("18446744073709551616", "/", "4294967296"), q("18446744073709551615", "/", "4294967296"),
        q("18446744073709551615", "%", "4294967296"), q("340282366920938463463374607431768211456", "/", "18446744073709551616"),
        q("340282366920938463463374607431768211455", "%", "18446744073709551616"),
    ]))
    t.append(("division_by_zero", [
        q(1, "/", 0), q(0, "/", 0), q(-1, "/", 0), q(1, "%", 0), q(0, "%", 0), q(-1, "%", 0),
        q(5, "/", "-0"), q(5, "%", "000"), q("123456789012345678901234567890", "/", 0),
        q(5, "+", 0), q("123456789012345678901234567890", "%", "-00"), q(0, "^", 0), q(9, "*", 0),
    ]))
    t.append(("power", [
        q(2, "^", 10), q(-2, "^", 3), q(-2, "^", 2), q(0, "^", 0), q(0, "^", 5), q(1, "^", 1000),
        q(-1, "^", 999), q(-1, "^", 1000), q(10, "^", 20), q(5, "^", 0), q(-5, "^", 0), q(-10, "^", 21),
        q(2, "^", -1), q(0, "^", -1), q(-3, "^", -2), q(1, "^", -1), q(2, "^", 64), q(2, "^", 63),
        q(2, "^", 32), q(2, "^", 31), q(3, "^", 100), q(-3, "^", 101), q(7, "^", 1), q(123456789, "^", 3),
        q(-123456789, "^", 7), q(999999999, "^", 2), q(1000000000, "^", 2), q("18446744073709551616", "^", 4),
        q(2, "^", 1000), q(-2, "^", 1001), q(10, "^", 0), q(10, "^", 1), q(10, "^", 100),
        q(12345678901234567890, "^", 30),
        # A "-0" exponent is zero, not negative: the result is 1, never "error".
        q(5, "^", "-0"), q(-5, "^", "-00"), q(0, "^", "-0"), q(2, "^", "-000000"), q("-0", "^", "-0"),
    ]))
    t.append(("compare", [
        q(1, "cmp", 2), q(2, "cmp", 1), q(2, "cmp", 2), q(-1, "cmp", -2), q(-2, "cmp", -1),
        q(-1, "cmp", 1), q(1, "cmp", -1), q(0, "cmp", 0), q(10, "cmp", 9), q(9, "cmp", 10),
        q(100, "cmp", 99), q(-100, "cmp", -99), q("12345678901234567890", "cmp", "12345678901234567891"),
        q("12345678901234567891", "cmp", "12345678901234567890"), q("12345678901234567890", "cmp", "12345678901234567890"),
        q("-12345678901234567890", "cmp", "-12345678901234567891"), q("1000000000000000000000", "cmp", "999999999999999999999"),
        q("-1000000000000000000000", "cmp", "-999999999999999999999"), q("9" * 50, "cmp", "1" + "0" * 50),
        q("1" + "0" * 50, "cmp", "9" * 50), q("-" + "9" * 50, "cmp", "-1" + "0" * 50),
    ]))
    t.append(("leading_zeros", [
        q("007", "+", "0008"), q("-000123", "*", "0002"), q("-000", "cmp", "0"), q("00", "cmp", "0000"),
        q("007", "cmp", "7"), q("0100", "/", "010"), q("0100", "%", "007"), q("-0100", "/", "-010"),
        q("000", "/", "007"), q("00002", "^", "0010"), q("0002", "^", "000"), q("-0002", "^", "003"), q("-0002", "^", "-000"),
        q("0", "-", "0000000000000000000000000000001"), q("-0000000000000000000000000000001", "-", "-0000000000000000000000000000001"),
        q("0000000000000000000000000000000000000000000000000000000000000000000000001", "+", "1"),
        q("-0000000000000000000000000000000000000000000000000000000000000000000000000", "cmp", "0"),
        q("00000000000000000000000000000000000000000000000000000000000000000000000000000", "*", "-9"),
        q("00000000000000000000000000000000000000000000000000000000000000000000000000000", "/", "-9"),
        q("00000000000000000000000000000000000000000000000000000000000000000000000000001", "/", "-0000000000000000000000001"),
        q("00000000000000000000000000000000000000000000000000000000000000000000000000000", "/", "-0000000000000000000000000"),
    ]))
    t.append(("multiply_small", [
        q(12345, "*", 6789), q(-12345, "*", 6789), q(12345, "*", -6789), q(-12345, "*", -6789),
        q(1, "*", 1), q(-1, "*", 1), q(0, "*", "123456789012345678901234567890"),
        q("123456789012345678901234567890", "*", 1), q("123456789012345678901234567890", "*", -1),
        q("4294967295", "*", "4294967295"), q("4294967296", "*", "4294967296"),
        q("18446744073709551615", "*", "18446744073709551615"), q("18446744073709551616", "*", "18446744073709551616"),
        q("999999999", "*", "999999999"), q("1000000000", "*", "1000000000"),
        q("999999999999999999", "*", "999999999999999999"), q("1000000000000000000", "*", "1000000000000000000"),
        q("12345678901234567890", "*", "98765432109876543210"), q("-12345678901234567890", "*", "98765432109876543210"),
        q("1" + "0" * 30, "*", "1" + "0" * 30), q("9" * 30, "*", "9" * 30), q("9" * 30, "*", "1" + "0" * 30),
        q("123456789", "*", "1000000000000000000000000000000"), q("2", "*", "5" * 40),
    ]))
    t.append(("mixed_small", [
        q(100, "+", 200), q(100, "-", 200), q(100, "*", 200), q(100, "/", 200), q(100, "%", 200),
        q(100, "^", 2), q(100, "cmp", 200), q(-100, "+", 200), q(-100, "-", 200), q(-100, "*", 200),
        q(-100, "/", 200), q(-100, "%", 200), q(-100, "^", 3), q(-100, "cmp", 200),
        q(200, "/", 100), q(-200, "/", 100), q(200, "%", 100), q(-201, "%", 100), q(201, "%", -100),
        q("31415926535897932384626433832795028841971", "+", "27182818284590452353602874713526624977572"),
        q("31415926535897932384626433832795028841971", "-", "27182818284590452353602874713526624977572"),
        q("31415926535897932384626433832795028841971", "*", "27182818284590452353602874713526624977572"),
        q("31415926535897932384626433832795028841971", "/", "27182818284590452353602874713526624977572"),
        q("31415926535897932384626433832795028841971", "%", "27182818284590452353602874713526624977572"),
        q("31415926535897932384626433832795028841971", "cmp", "27182818284590452353602874713526624977572"),
        q("-31415926535897932384626433832795028841971", "/", "27182818284590452353602874713526624977572"),
        q("-31415926535897932384626433832795028841971", "%", "27182818284590452353602874713526624977572"),
        q("-31415926535897932384626433832795028841971", "%", "-27182818284590452353602874713526624977572"),
        q("31415926535897932384626433832795028841971", "%", "-27182818284590452353602874713526624977572"),
        q("31415926535897932384626433832795028841971", "^", "3"), q("-31415926535897932384626433832795028841971", "^", "0"),
        q("31415926535897932384626433832795028841971", "/", "0"), q("31415926535897932384626433832795028841971", "^", "-3"),
    ]))
    # Limb-boundary values for base 10^9, 10^18, 2^32, 2^64 implementations.
    limb_vals = ["999999999", "1000000000", "1000000001", "999999999999999999", "1000000000000000000",
                 "4294967295", "4294967296", "4294967297", "18446744073709551615", "18446744073709551616",
                 "18446744073709551617", "9999999999999999999", "99999999999999999999", "1" + "0" * 27,
                 "9" * 27, "9" * 36, "1" + "0" * 36, "1" + "0" * 18 + "1", "5" * 9 + "5" * 9, "1" + "0" * 9 + "1"]
    lines = []
    for a in limb_vals:
        for b in ["1", "999999999", "1000000000", "18446744073709551616", "9" * 18]:
            for op in OPS:
                if op == "^":
                    lines.append(q(a, op, 3))
                else:
                    lines.append(q(a, op, b))
                    lines.append(q("-" + a, op, b))
    t.append(("limb_boundaries", lines))
    # Long-division cases where the trial quotient digit needs correction, the
    # quotient has interior zero limbs, or the divisor is longer than the dividend.
    lines = []
    B = 10 ** 9
    cases = [
        (B ** 4 - 1, B ** 2 - 1), (B ** 4, B ** 2), (B ** 4 - 1, B ** 2), (B ** 4, B ** 2 + 1),
        (B ** 5 + 1, B ** 3 - 1), (B ** 6 - B ** 3, B ** 3 - 1), (B ** 6, B ** 3 + 1),
        ((B - 1) * B ** 3 + (B - 1), (B - 1) * B + 1), (B ** 3 * (B - 1) + B - 1, B ** 2 - B + 1),
        (2 ** 128 - 1, 2 ** 64 - 1), (2 ** 128, 2 ** 64 + 1), (2 ** 192 - 2 ** 64, 2 ** 64 - 1),
        (2 ** 256 - 1, 2 ** 127 + 1), (10 ** 40 + 1, 10 ** 20 + 1), (10 ** 40, 10 ** 20 - 1),
        (123456789 * B ** 5 + 987654321, B ** 2 + 1), (7 * B ** 7 + 3, 7 * B ** 3 + 1),
        (10 ** 60 + 10 ** 30, 10 ** 30 + 1), (10 ** 60, 3), (10 ** 60 - 1, 7), (10 ** 60 - 1, 10 ** 60),
        (10 ** 60 - 1, 10 ** 60 - 2), (10 ** 60, 10 ** 60), (10 ** 30, 10 ** 60), (1, 10 ** 60),
        (10 ** 60 - 1, 10 ** 59), (10 ** 60 + 10 ** 59, 10 ** 59 + 1), (B ** 8 - 1, B ** 4 - B),
        (int("8" * 45), int("9" * 20)), (int("1" * 50), int("11")), (int("1" * 50), int("1" * 25)),
        (int("1" * 50), int("1" * 26)), (int("1" * 50), int("1" * 24)),
    ]
    for a, b in cases:
        for sa in (1, -1):
            for sb in (1, -1):
                lines.append(q(sa * a, "/", sb * b))
                lines.append(q(sa * a, "%", sb * b))
    t.append(("division_tricky", lines))
    t.append(("known_values", known_values()))
    return t


def generated():
    """Returns list of (name, lines) for seeded random and performance cases."""
    t = []
    rng = random.Random(1001)
    t.append(("random_tiny", random_queries(rng, 500, 20, OPS, pow_max_exp=40, pow_max_base_digits=6)))
    rng = random.Random(1002)
    t.append(("random_medium", random_queries(rng, 500, 200, OPS, pow_max_exp=200, pow_max_base_digits=20)))
    rng = random.Random(1003)
    t.append(("random_2000_addsub", random_queries(rng, 300, 2000, ["+", "-"])))
    rng = random.Random(1004)
    t.append(("random_2000_mul", random_queries(rng, 200, 2000, ["*"])))
    rng = random.Random(1005)
    t.append(("random_2000_divmod", random_queries(rng, 200, 2000, ["/", "%"])))
    rng = random.Random(1006)
    t.append(("random_2000_mixed", random_queries(rng, 400, 2000, OPS, pow_max_exp=500, pow_max_base_digits=40)))

    # Division stress: quotients with runs of zero limbs, divisors that are a
    # near-prefix of the dividend, and dividends built as q*d + r with random
    # small r so the answer is known to be exact.
    rng = random.Random(1007)
    lines = []
    for _ in range(150):
        nd = rng.randint(1, 1500)
        d = int(rand_digits(rng, nd))
        kind = rng.random()
        if kind < 0.3:
            qv = int("1" + "0" * rng.randint(0, 1500))
        elif kind < 0.6:
            qv = int(rand_digits(rng, rng.randint(1, 300))) * 10 ** rng.randint(0, 1200)
        elif kind < 0.8:
            qv = int(rand_digits(rng, rng.randint(1, 1500)))
        else:
            qv = rng.randint(0, 3)
        r = rng.randint(0, d - 1) if rng.random() < 0.5 else rng.randint(0, min(d - 1, 5))
        a = qv * d + r
        sa = rng.choice((1, -1))
        sb = rng.choice((1, -1))
        lines.append(q(sa * a, "/", sb * d))
        lines.append(q(sa * a, "%", sb * d))
        # Divisor sharing a long prefix with the dividend forces trial-digit corrections.
        s = str(a)
        cut = rng.randint(1, len(s))
        pre = int(s[:cut])
        if pre:
            lines.append(q(sa * a, "/", sb * pre))
            lines.append(q(sa * a, "%", sb * pre))
    t.append(("division_stress", lines))

    rng = random.Random(1008)
    lines = []
    for _ in range(40):
        base_digits = rng.randint(1, 50)
        base = rand_int_str(rng, base_digits)
        max_exp = min(5000, 100000 // base_digits)
        lines.append(q(base, "^", rng.randint(0, max_exp)))
    lines += [q(2, "^", 5000), q(-3, "^", 4999), q(10, "^", 5000), q("9" * 20, "^", 5000), q("1" + "0" * 19, "^", 5000)]
    t.append(("power_large", lines))

    rng = random.Random(1009)
    lines = []
    for _ in range(30):
        lines.append(q(rand_int_str(rng, 50000, 40000), rng.choice(["+", "-"]), rand_int_str(rng, 50000, 40000)))
    t.append(("addsub_50k", lines))

    rng = random.Random(1010)
    lines = []
    for _ in range(6):
        lines.append(q(rand_int_str(rng, 50000, 45000), "*", rand_int_str(rng, 50000, 45000)))
    lines.append(q("9" * 50000, "*", "9" * 50000))
    lines.append(q("-" + "9" * 50000, "*", "1" + "0" * 49999))
    t.append(("mul_50k", lines))

    rng = random.Random(1011)
    lines = []
    for _ in range(6):
        lines.append(q(rand_int_str(rng, 50000, 45000), rng.choice(["/", "%"]), rand_int_str(rng, 25000, 20000)))
    lines.append(q("9" * 50000, "/", "9" * 25000))
    lines.append(q("9" * 50000, "%", "9" * 25001))
    lines.append(q("1" + "0" * 49999, "/", "3"))
    lines.append(q("-" + "9" * 50000, "/", "-" + "1" + "0" * 49999))
    lines.append(q("1" + "0" * 49999, "%", "7" * 30000))
    t.append(("divmod_50k", lines))

    rng = random.Random(1012)
    t.append(("many_small", random_queries(rng, 10000, 40, OPS, pow_max_exp=30, pow_max_base_digits=8)))

    rng = random.Random(1013)
    lines = []
    for _ in range(100):
        n = rng.randint(1000, 30000)
        a = rand_digits(rng, n)
        kind = rng.random()
        if kind < 0.3:
            b = a
        elif kind < 0.6:
            b = a[:-1] + str((int(a[-1]) + 1) % 10)
        elif kind < 0.8:
            i = rng.randrange(n)
            b = a[:i] + str((int(a[i]) + 1) % 10) + a[i + 1:]
        else:
            b = rand_digits(rng, n + rng.choice((-1, 1)))
        sa = rng.choice(("", "-"))
        sb = rng.choice(("", "-"))
        lines.append(q(sa + a, "cmp", sb + b))
    t.append(("compare_large", lines))

    rng = random.Random(1014)
    lines = []
    for _ in range(16):
        n = rng.randint(30000, 50000)
        a = rand_digits(rng, n)
        delta = rand_int_str(rng, rng.randint(1, 20))
        b = str(int(a) + int(delta))
        sa = rng.choice((1, -1))
        lines.append(q(sa * int(a), "-", sa * int(b)))
        lines.append(q(sa * int(a), "+", -sa * int(b)))
        lines.append(q(sa * int(a), "cmp", sa * int(b)))
    lines.append(q("9" * 50000, "-", "9" * 50000))
    lines.append(q("-" + "9" * 50000, "+", "9" * 50000))
    lines.append(q("1" + "0" * 49999, "-", "9" * 49999))
    lines.append(q("1" + "0" * 49999, "-", "1"))
    lines.append(q("9" * 49999, "+", "1"))
    t.append(("cancellation_50k", lines))

    rng = random.Random(1015)
    lines = random_queries(rng, 60, 20000, ["+", "-", "*", "cmp"])
    lines += random_queries(rng, 20, 20000, ["/", "%"])
    lines += random_queries(rng, 10, 20000, ["^"], pow_max_exp=2000, pow_max_base_digits=50)
    rng.shuffle(lines)
    t.append(("mixed_large", lines))
    return t


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))
    cases = handwritten() + generated()
    total = 0
    for i, (name, lines) in enumerate(cases, start=1):
        data = "\n".join(lines) + "\n"
        # A few inputs deliberately omit the trailing newline.
        if name in ("single_add", "leading_zeros"):
            data = data.rstrip("\n")
        base = os.path.join(TESTS, f"{i:03d}_{name}")
        with open(base + ".in", "w") as f:
            f.write(data)
        res = subprocess.run([sys.executable, REF], input=data.encode(), capture_output=True, check=True)
        with open(base + ".out", "wb") as f:
            f.write(res.stdout)
        total += len(data) + len(res.stdout)
        print(f"{i:03d}_{name}: {len(lines)} queries, {len(data)} in, {len(res.stdout)} out")
    print(f"{len(cases)} tests, {total / 1e6:.1f} MB total")


if __name__ == "__main__":
    main()
