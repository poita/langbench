#!/usr/bin/env python3
"""Generate tests/*.in deterministically and tests/*.out via reference/main.py.

Hand-written edge cases are embedded as literals; random cases use fixed
seeds. Every expected output that the host FPU can compute is cross-checked
against Python's float64 arithmetic rounded to binary32 with struct. Rounding
binary32 operands through binary64 and then to binary32 is provably innocuous
for + - * / sqrt because 53 >= 2*24 + 2 bits, so the check is exact wherever
it applies; NaN operands, division by zero and negative sqrt operands are
handled specially by the spec and are skipped by the host check.
"""
import math
import os
import random
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(HERE, "reference"))
import main as ref  # noqa: E402

QNAN = 0x7FC00000
POS_INF = 0x7F800000
NEG_INF = 0xFF800000
POS_ZERO = 0x00000000
NEG_ZERO = 0x80000000
MIN_DENORM = 0x00000001
MAX_DENORM = 0x007FFFFF
MIN_NORMAL = 0x00800000
MAX_NORMAL = 0x7F7FFFFF
ONE = 0x3F800000
TWO = 0x40000000
HALF = 0x3F000000

BIN_OPS = ["add", "sub", "mul", "div"]
ALL_OPS = BIN_OPS + ["sqrt"]


def neg(x):
    return x ^ 0x80000000


def bits_of(f):
    """binary32 bit pattern nearest to a Python float (used only to build inputs)."""
    return struct.unpack(">I", struct.pack(">f", f))[0]


def make(sign, biased_exp, frac):
    return (sign << 31) | (biased_exp << 23) | frac


def pack_exact(sign, m, e):
    """Bit pattern of sign * m * 2**e, which must be exactly representable."""
    b = ref.round_pack(sign, m, e)
    k, s, mm, ee = ref.unpack(b)
    assert k == "fin" and (mm << max(0, ee - e)) == (m << max(0, e - ee)), (m, e)
    return b


def q(op, a, b=None):
    if op == "sqrt":
        return "sqrt %08x" % a
    return "%s %08x %08x" % (op, a, b)


# --------------------------------------------------------------------------
# Hand-written cases
# --------------------------------------------------------------------------

SPECIALS = [
    POS_ZERO, NEG_ZERO, POS_INF, NEG_INF, QNAN, 0x7F800001, 0xFFC00000,
    MIN_DENORM, neg(MIN_DENORM), MAX_DENORM, neg(MAX_DENORM),
    MIN_NORMAL, neg(MIN_NORMAL), MAX_NORMAL, neg(MAX_NORMAL),
    ONE, neg(ONE), TWO, HALF, 0x40490FDB,
]


def handwritten():
    """Returns list of (name, lines) or (name, lines, trailing_newline)."""
    t = []
    t.append(("single_add", [q("add", ONE, ONE)]))

    # Written without a trailing newline on the last line, as the spec permits.
    # Also covers nonzero results that round to zero, which keep the XOR sign.
    t.append(("no_trailing_newline", [
        q("sub", ONE, ONE), q("mul", neg(MIN_DENORM), HALF), q("mul", MIN_DENORM, neg(HALF)),
        q("div", neg(MIN_DENORM), TWO), q("div", neg(MIN_DENORM), neg(TWO)), q("sqrt", TWO),
    ], False))

    t.append(("signed_zeros", [
        q("add", POS_ZERO, POS_ZERO), q("add", NEG_ZERO, NEG_ZERO),
        q("add", POS_ZERO, NEG_ZERO), q("add", NEG_ZERO, POS_ZERO),
        q("sub", POS_ZERO, POS_ZERO), q("sub", NEG_ZERO, NEG_ZERO),
        q("sub", POS_ZERO, NEG_ZERO), q("sub", NEG_ZERO, POS_ZERO),
        q("add", ONE, neg(ONE)), q("add", neg(ONE), ONE), q("sub", ONE, ONE), q("sub", neg(ONE), neg(ONE)),
        q("mul", POS_ZERO, neg(ONE)), q("mul", neg(ONE), POS_ZERO), q("mul", NEG_ZERO, ONE),
        q("mul", NEG_ZERO, NEG_ZERO), q("mul", NEG_ZERO, POS_ZERO), q("mul", POS_ZERO, POS_ZERO),
        q("div", POS_ZERO, neg(ONE)), q("div", NEG_ZERO, ONE), q("div", NEG_ZERO, neg(ONE)),
        q("div", POS_ZERO, MAX_NORMAL), q("div", NEG_ZERO, POS_INF), q("div", POS_ZERO, NEG_INF),
        q("div", ONE, NEG_INF), q("div", neg(ONE), NEG_INF), q("div", MIN_DENORM, POS_INF),
        q("sqrt", POS_ZERO), q("sqrt", NEG_ZERO),
        q("add", NEG_ZERO, ONE), q("add", ONE, NEG_ZERO), q("sub", NEG_ZERO, ONE), q("sub", ONE, NEG_ZERO),
        q("add", NEG_ZERO, neg(MIN_DENORM)), q("sub", NEG_ZERO, MIN_DENORM), q("add", MIN_DENORM, neg(MIN_DENORM)),
        q("sub", MIN_DENORM, MIN_DENORM), q("sub", neg(MIN_DENORM), neg(MIN_DENORM)),
    ]))

    nans = [QNAN, 0x7F800001, 0x7FFFFFFF, 0xFFC00000, 0xFF800001, 0xFFFFFFFF, 0x7FA00000, 0xFFC12345]
    lines = []
    for n in nans:
        lines += [q("add", n, ONE), q("add", ONE, n), q("sub", n, n), q("mul", n, POS_ZERO),
                  q("mul", POS_INF, n), q("div", n, POS_ZERO), q("div", POS_ZERO, n), q("sqrt", n)]
    t.append(("nan_inputs", lines))

    t.append(("infinities", [
        q("add", POS_INF, POS_INF), q("add", NEG_INF, NEG_INF), q("add", POS_INF, NEG_INF), q("add", NEG_INF, POS_INF),
        q("sub", POS_INF, POS_INF), q("sub", NEG_INF, NEG_INF), q("sub", POS_INF, NEG_INF), q("sub", NEG_INF, POS_INF),
        q("add", POS_INF, ONE), q("add", ONE, NEG_INF), q("add", POS_INF, MAX_NORMAL), q("sub", neg(MAX_NORMAL), POS_INF),
        q("add", POS_INF, POS_ZERO), q("add", NEG_ZERO, NEG_INF),
        q("mul", POS_INF, POS_INF), q("mul", POS_INF, NEG_INF), q("mul", NEG_INF, NEG_INF),
        q("mul", POS_INF, POS_ZERO), q("mul", POS_ZERO, NEG_INF), q("mul", NEG_ZERO, NEG_INF),
        q("mul", POS_INF, MIN_DENORM), q("mul", neg(MIN_DENORM), POS_INF), q("mul", NEG_INF, neg(ONE)),
        q("div", POS_INF, POS_INF), q("div", POS_INF, NEG_INF), q("div", NEG_INF, NEG_INF),
        q("div", POS_INF, POS_ZERO), q("div", POS_INF, NEG_ZERO), q("div", NEG_INF, NEG_ZERO),
        q("div", POS_INF, ONE), q("div", POS_INF, neg(MAX_NORMAL)), q("div", ONE, POS_INF), q("div", neg(ONE), POS_INF),
        q("div", MAX_NORMAL, NEG_INF), q("div", POS_ZERO, POS_INF),
        q("sqrt", POS_INF), q("sqrt", NEG_INF),
    ]))

    t.append(("division_by_zero", [
        q("div", ONE, POS_ZERO), q("div", ONE, NEG_ZERO), q("div", neg(ONE), POS_ZERO), q("div", neg(ONE), NEG_ZERO),
        q("div", POS_ZERO, POS_ZERO), q("div", POS_ZERO, NEG_ZERO), q("div", NEG_ZERO, POS_ZERO), q("div", NEG_ZERO, NEG_ZERO),
        q("div", MIN_DENORM, POS_ZERO), q("div", neg(MIN_DENORM), NEG_ZERO), q("div", MAX_NORMAL, NEG_ZERO),
        q("div", POS_INF, POS_ZERO), q("div", NEG_INF, POS_ZERO), q("div", QNAN, POS_ZERO),
    ]))

    lines = []
    for op in BIN_OPS:
        for a in SPECIALS:
            for b in SPECIALS:
                lines.append(q(op, a, b))
    for a in SPECIALS:
        lines.append(q("sqrt", a))
    t.append(("special_grid", lines))

    t.append(("exact_small", [
        q("add", ONE, TWO), q("add", TWO, ONE), q("sub", TWO, ONE), q("sub", ONE, TWO),
        q("mul", TWO, TWO), q("mul", bits_of(3.0), bits_of(7.0)), q("div", bits_of(6.0), bits_of(3.0)),
        q("div", ONE, TWO), q("div", ONE, bits_of(4.0)), q("div", bits_of(-6.0), bits_of(3.0)),
        q("add", bits_of(0.5), bits_of(0.25)), q("sub", bits_of(0.25), bits_of(0.5)),
        q("mul", bits_of(0.5), bits_of(0.5)), q("mul", bits_of(-0.5), bits_of(0.5)),
        q("add", bits_of(16777215.0), ONE), q("add", bits_of(16777216.0), ONE), q("add", bits_of(16777216.0), TWO),
        q("sub", bits_of(16777216.0), ONE), q("add", bits_of(16777217.0 - 1), bits_of(3.0)),
        q("mul", bits_of(4096.0), bits_of(4096.0)), q("mul", bits_of(65536.0), bits_of(65536.0)),
        q("sqrt", bits_of(4.0)), q("sqrt", bits_of(9.0)), q("sqrt", bits_of(0.25)), q("sqrt", bits_of(1.0)),
        q("sqrt", bits_of(16777216.0)), q("sqrt", bits_of(2.0 ** 100)), q("sqrt", bits_of(2.0 ** -100)),
        q("sqrt", bits_of(2.0 ** -126)), q("sqrt", bits_of(2.0 ** -148)), q("sqrt", bits_of(2.0 ** 126)),
        q("mul", ONE, ONE), q("div", ONE, ONE), q("mul", neg(ONE), neg(ONE)), q("div", neg(ONE), neg(ONE)),
    ]))

    t.append(("cancellation", [
        q("sub", ONE, bits_of(1.0 - 2 ** -24)), q("sub", bits_of(1.0 + 2 ** -23), ONE),
        q("sub", ONE, bits_of(1.0 + 2 ** -23)), q("add", ONE, bits_of(-(1.0 - 2 ** -24))),
        q("sub", bits_of(2.0), bits_of(2.0 - 2 ** -23)), q("sub", bits_of(2.0 - 2 ** -23), bits_of(2.0)),
        q("sub", MIN_NORMAL, MAX_DENORM), q("sub", MAX_DENORM, MIN_NORMAL), q("sub", MIN_NORMAL, MIN_DENORM),
        q("sub", bits_of(2.0 ** -125), MIN_NORMAL), q("sub", bits_of(3.0 * 2 ** -126), bits_of(2.0 ** -126)),
        q("sub", MAX_NORMAL, bits_of(2.0 ** 127)), q("sub", MAX_NORMAL, bits_of(float(2 ** 127 + 2 ** 104))),
        q("sub", bits_of(1e10), bits_of(1e10 - 1024.0)), q("sub", bits_of(123456792.0), bits_of(123456784.0)),
        q("add", bits_of(0.1), bits_of(-0.1)), q("sub", bits_of(0.3), bits_of(0.1)),
        q("sub", bits_of(1.0), bits_of(0.9)), q("sub", bits_of(100.0), bits_of(99.99)),
        q("sub", bits_of(2.0 ** 24), bits_of(2.0 ** 24 - 1)), q("sub", bits_of(2.0 ** 25), bits_of(2.0 ** 25 - 2)),
    ]))

    # Ties in addition: b is exactly half an ulp of a (or of the result).
    lines = []
    for a in [ONE, bits_of(1.0 + 2 ** -23), bits_of(3.0), bits_of(2.0 - 2 ** -23), bits_of(1.5), bits_of(2.0 ** 24 + 2),
              bits_of(2.0 ** 24), bits_of(1.0 + 2 ** -22)]:
        _, _, m, e = ref.unpack(a)
        half_ulp = pack_exact(0, 1, e - 1)
        quarter_ulp = pack_exact(0, 1, e - 2)
        three_q = pack_exact(0, 3, e - 2)
        lines += [q("add", a, half_ulp), q("add", a, neg(half_ulp)), q("sub", a, half_ulp),
                  q("add", a, quarter_ulp), q("add", a, three_q), q("add", neg(a), half_ulp),
                  q("add", a, pack_exact(0, 3, e - 1)), q("add", half_ulp, a), q("add", a, pack_exact(0, 5, e - 2))]
    # Just above and just below a tie via sticky bits far away.
    lines += [
        q("add", ONE, bits_of(2 ** -24)), q("add", ONE, bits_of(2 ** -24 + 2 ** -47)),
        q("add", ONE, bits_of(2 ** -24 - 2 ** -47)), q("add", ONE, bits_of(2 ** -25)),
        q("add", bits_of(1.0 + 2 ** -23), bits_of(2 ** -24)), q("add", bits_of(1.0 + 2 ** -23), bits_of(2 ** -24 - 2 ** -47)),
        q("add", bits_of(1.0 + 2 ** -23), bits_of(2 ** -24 + 2 ** -47)),
        q("sub", ONE, bits_of(2 ** -25)), q("sub", ONE, bits_of(2 ** -25 + 2 ** -48)), q("sub", ONE, bits_of(2 ** -25 - 2 ** -48)),
        q("sub", ONE, bits_of(2 ** -24)), q("sub", ONE, bits_of(2 ** -24 + 2 ** -48)),
        q("add", ONE, MIN_DENORM), q("sub", ONE, MIN_DENORM), q("add", MAX_NORMAL, MIN_DENORM),
        q("add", bits_of(2.0 ** 100), bits_of(2.0 ** 76)), q("add", bits_of(2.0 ** 100), bits_of(2.0 ** 76 + 2 ** 52)),
    ]
    t.append(("rounding_ties_add", lines))

    # Ties in multiplication: exact product has 25 significant bits ending in 1.
    lines = []
    for f1, f2, e1, e2 in [(3, 0x555555, 0, 0), (5, 0x333333 * 1, 0, 0), (0xFFFFFF, 0xFFFFFF, 0, 0),
                           (0x800001, 3, 0, 0), (0x800001, 0x800001, 0, 0), (0xAAAAAB, 3, 0, 0),
                           (0x800003, 0x800001, -30, 40), (0xBFFFFF, 3, 5, -7), (0x1000001 >> 1, 3, 0, 0),
                           (7, 0x492493, 0, 0), (0x924925, 7, 10, -50), (0xFFFFFF, 3, 0, 0)]:
        a = pack_exact(0, f1, e1)
        b = pack_exact(0, f2, e2)
        lines += [q("mul", a, b), q("mul", b, a), q("mul", neg(a), b), q("mul", neg(a), neg(b))]
    lines += [
        q("mul", bits_of(1.0 + 2 ** -23), bits_of(1.0 + 2 ** -23)),
        q("mul", bits_of(1.0 + 2 ** -23), bits_of(1.0 + 2 ** -22)),
        q("mul", bits_of(1.0 + 2 ** -23), bits_of(1.0 + 2 ** -1)),
        q("mul", bits_of(1.0 + 2 ** -23), bits_of(1.0 - 2 ** -24)),
        q("mul", bits_of(1.0 - 2 ** -24), bits_of(1.0 - 2 ** -24)),
        q("mul", bits_of(1.0 + 2 ** -22), bits_of(1.0 + 2 ** -22)),
        q("mul", bits_of(0.1), bits_of(10.0)), q("mul", bits_of(0.1), bits_of(3.0)), q("mul", bits_of(1.1), bits_of(1.1)),
        q("mul", bits_of(3.0), bits_of(1.0 / 3.0)), q("mul", bits_of(math.pi), bits_of(math.e)),
    ]
    t.append(("rounding_ties_mul", lines))

    lines = [
        q("mul", MIN_NORMAL, HALF), q("mul", MIN_NORMAL, bits_of(0.25)), q("mul", MIN_DENORM, HALF),
        q("mul", bits_of(3.0 * 2 ** -149), HALF), q("mul", bits_of(5.0 * 2 ** -149), HALF), q("mul", bits_of(3.0 * 2 ** -149), bits_of(0.25)),
        q("mul", MIN_DENORM, bits_of(0.75)), q("mul", MIN_DENORM, bits_of(0.5 + 2 ** -23)), q("mul", MIN_DENORM, bits_of(0.5 - 2 ** -24)),
        q("mul", MIN_DENORM, bits_of(1.5)), q("mul", MIN_DENORM, bits_of(1.5 + 2 ** -23)), q("mul", MIN_DENORM, bits_of(2.5)),
        q("mul", MAX_DENORM, TWO), q("mul", MAX_DENORM, bits_of(1.0 + 2 ** -23)), q("mul", MAX_DENORM, bits_of(1.0 + 2 ** -22)),
        q("mul", bits_of(2.0 ** -75), bits_of(2.0 ** -75)), q("mul", bits_of(2.0 ** -74), bits_of(2.0 ** -75)),
        q("mul", bits_of(2.0 ** -74), bits_of(2.0 ** -76)), q("mul", bits_of(-(2.0 ** -75)), bits_of(2.0 ** -75)),
        q("mul", bits_of(1.5 * 2 ** -75), bits_of(2.0 ** -75)), q("mul", bits_of(2.0 ** -70), bits_of(2.0 ** -70)),
        q("mul", bits_of(1.0 + 2 ** -23), bits_of(2.0 ** -126)), q("mul", bits_of(1.0 + 2 ** -22), bits_of(2.0 ** -127)),
        q("mul", bits_of(1.0 - 2 ** -24), bits_of(2.0 ** -126)), q("mul", bits_of(1.0 - 2 ** -24), bits_of(2.0 ** -125)),
        q("mul", MIN_DENORM, MIN_DENORM), q("mul", MAX_DENORM, MAX_DENORM), q("mul", MIN_DENORM, MAX_NORMAL),
        q("mul", MAX_DENORM, MAX_NORMAL), q("mul", MIN_DENORM, bits_of(2.0 ** 127)), q("mul", MIN_DENORM, bits_of(2.0 ** 100)),
        q("div", MIN_DENORM, TWO), q("div", bits_of(3.0 * 2 ** -149), TWO), q("div", bits_of(5.0 * 2 ** -149), TWO),
        q("div", bits_of(7.0 * 2 ** -149), TWO), q("div", MIN_DENORM, bits_of(4.0)), q("div", bits_of(3.0 * 2 ** -149), bits_of(4.0)),
        q("div", bits_of(5.0 * 2 ** -149), bits_of(4.0)), q("div", MIN_DENORM, bits_of(3.0)), q("div", bits_of(2.0 * 2 ** -149), bits_of(3.0)),
        q("div", MIN_DENORM, bits_of(1.5)), q("div", MIN_DENORM, bits_of(2.0 - 2 ** -23)), q("div", MIN_DENORM, bits_of(2.0 + 2 ** -22)),
        q("div", MIN_NORMAL, TWO), q("div", MIN_NORMAL, bits_of(3.0)), q("div", MIN_NORMAL, MAX_NORMAL),
        q("div", ONE, MAX_NORMAL), q("div", bits_of(2.0 ** -100), bits_of(2.0 ** 49)), q("div", bits_of(2.0 ** -100), bits_of(2.0 ** 50)),
        q("div", bits_of(2.0 ** -100), bits_of(3.0 * 2 ** 48)), q("div", MAX_DENORM, bits_of(3.0)), q("div", MAX_DENORM, bits_of(1.0 + 2 ** -23)),
        q("div", MIN_DENORM, MIN_DENORM), q("div", MAX_DENORM, MIN_DENORM), q("div", MIN_DENORM, MAX_DENORM), q("div", MIN_DENORM, MAX_NORMAL),
        q("div", bits_of(2.0 ** -126), bits_of(2.0 ** 23)), q("div", bits_of(2.0 ** -126), bits_of(2.0 ** 24)),
        q("div", bits_of(2.0 ** -126), bits_of(2.0 ** 25)), q("div", bits_of(3.0 * 2 ** -126), bits_of(2.0 ** 24)),
        q("add", MIN_DENORM, MIN_DENORM), q("add", MAX_DENORM, MIN_DENORM), q("add", MAX_DENORM, MAX_DENORM),
        q("sub", MIN_NORMAL, MIN_DENORM), q("sub", bits_of(2.0 ** -125), MIN_DENORM), q("add", MIN_NORMAL, MIN_DENORM),
        q("add", bits_of(2.0 ** -125), MIN_DENORM), q("add", bits_of(2.0 ** -125), bits_of(3.0 * 2 ** -149)),
        q("sqrt", MIN_DENORM), q("sqrt", bits_of(4.0 * 2 ** -149)), q("sqrt", MAX_DENORM), q("sqrt", MIN_NORMAL),
        q("sqrt", bits_of(2.0 * 2 ** -149)), q("sqrt", bits_of(3.0 * 2 ** -149)), q("sqrt", bits_of(2.0 ** -126 * 0.5)),
    ]
    t.append(("denormal_results", lines))

    lines = []
    dens = [MIN_DENORM, 0x00000002, 0x00000003, 0x00000007, 0x00000100, 0x00001234, 0x00400000, 0x00400001, 0x007FFFFE, MAX_DENORM]
    for a in dens:
        for b in dens:
            lines += [q("add", a, b), q("sub", a, b), q("mul", a, b), q("div", a, b), q("mul", a, neg(b)), q("div", neg(a), b)]
        lines += [q("sqrt", a), q("add", a, ONE), q("sub", ONE, a), q("mul", a, bits_of(2.0 ** 100)),
                  q("mul", a, bits_of(2.0 ** 127)), q("div", a, bits_of(2.0 ** -100)), q("div", ONE, a), q("div", MAX_NORMAL, a),
                  q("div", a, bits_of(2.0 ** -149 * 2 ** 23)), q("mul", a, bits_of(1.0 + 2 ** -23)), q("mul", a, bits_of(0.99))]
    t.append(("denormal_operands", lines))

    lines = [
        q("mul", MAX_NORMAL, TWO), q("mul", MAX_NORMAL, bits_of(1.0 + 2 ** -23)), q("mul", MAX_NORMAL, bits_of(1.0 + 2 ** -24 * 2)),
        q("mul", MAX_NORMAL, MAX_NORMAL), q("mul", neg(MAX_NORMAL), MAX_NORMAL), q("mul", bits_of(2.0 ** 64), bits_of(2.0 ** 64)),
        q("mul", bits_of(2.0 ** 64), bits_of(2.0 ** 63)), q("mul", bits_of(2.0 ** 64), bits_of(-(2.0 ** 63) * (1 + 2 ** -23))),
        q("mul", bits_of(2.0 ** 100), bits_of(2.0 ** 28)), q("mul", bits_of(2.0 ** 100), bits_of(2.0 ** 27 * (2 - 2 ** -23))),
        q("mul", bits_of(2.0 ** 100), bits_of(2.0 ** 27 * (2 - 2 ** -22))),
        q("add", MAX_NORMAL, MAX_NORMAL), q("add", neg(MAX_NORMAL), neg(MAX_NORMAL)), q("sub", MAX_NORMAL, neg(MAX_NORMAL)),
        q("add", MAX_NORMAL, bits_of(2.0 ** 104)), q("add", MAX_NORMAL, bits_of(2.0 ** 103)), q("add", MAX_NORMAL, bits_of(2.0 ** 103 - 2 ** 79)),
        q("add", MAX_NORMAL, bits_of(2.0 ** 103 + 2 ** 80)), q("add", MAX_NORMAL, bits_of(2.0 ** 102)), q("add", MAX_NORMAL, ONE),
        q("add", bits_of(2.0 ** 127), bits_of(2.0 ** 127)), q("add", bits_of(2.0 ** 127), bits_of(2.0 ** 127 * (1 - 2 ** -24))),
        q("sub", neg(MAX_NORMAL), bits_of(2.0 ** 103)), q("sub", neg(MAX_NORMAL), bits_of(2.0 ** 102)),
        q("div", MAX_NORMAL, HALF), q("div", MAX_NORMAL, bits_of(0.5 * (1 - 2 ** -24))), q("div", MAX_NORMAL, bits_of(1.0 - 2 ** -24)),
        q("div", ONE, MIN_DENORM), q("div", ONE, MIN_NORMAL), q("div", TWO, MIN_NORMAL), q("div", bits_of(4.0), MIN_NORMAL),
        q("div", bits_of(2.0 ** 100), bits_of(2.0 ** -28)), q("div", bits_of(2.0 ** 100), bits_of(2.0 ** -27)),
        q("div", bits_of(2.0 ** 100), bits_of(2.0 ** -27 * (1 + 2 ** -23))), q("div", MAX_NORMAL, MIN_DENORM), q("div", neg(MAX_NORMAL), MIN_DENORM),
        q("div", MIN_NORMAL, MIN_DENORM), q("div", MAX_DENORM, MIN_DENORM), q("div", bits_of(2.0 ** 23), MIN_DENORM),
        q("sqrt", MAX_NORMAL), q("sqrt", bits_of(2.0 ** 127)), q("sqrt", bits_of(2.0 ** 126)),
    ]
    t.append(("overflow", lines))

    lines = []
    consts = [1.0 / 3.0, 2.0 / 3.0, 0.1, 0.2, 0.3, 0.7, 1.0 / 7.0, 1e-5, 1e5, math.pi, math.e, math.sqrt(2), 1.0 / 10.0, 1.0 / 49.0]
    nums = [ONE, TWO, bits_of(3.0), bits_of(7.0), bits_of(10.0), bits_of(0.1), bits_of(0.3), bits_of(49.0), bits_of(1e10), bits_of(1e-10),
            bits_of(math.pi), bits_of(-3.0), bits_of(-7.0), bits_of(1.0 / 3.0), bits_of(2.0 / 3.0)]
    for a in nums:
        for b in nums:
            lines.append(q("div", a, b))
    for c in consts:
        lines += [q("div", ONE, bits_of(c)), q("div", bits_of(c), ONE), q("div", bits_of(c), bits_of(c)), q("mul", bits_of(c), bits_of(1.0 / c))]
    t.append(("division_known", lines))

    lines = []
    for f in [2.0, 3.0, 5.0, 0.5, 10.0, 100.0, 1e10, 1e-10, 1e20, 1e-20, 1e30, 1e-30, 1e38, 1e-38, 0.1, 0.2, 0.3, 3.3, 7.7, 123456.789,
              2.0 ** 126, 2.0 ** 125, 2.0 ** -125, 2.0 ** -126, 2.0 ** -127, 2.0 ** -140, 1.5, 2.25, 6.25, 1e-40, 1e-45,
              0.9999999, 1.0000001, 3.9999998, 4.0000005, 2 ** 24 - 1.0, 2 ** 23 + 1.0, 2 ** 25 - 2.0, 1.0 + 2 ** -23, 1.0 - 2 ** -24,
              1.0 + 2 ** -22, 2.0 - 2 ** -23, 2.0 + 2 ** -22, 4.0 - 2 ** -22, 4.0 + 2 ** -21]:
        lines.append(q("sqrt", bits_of(f)))
        lines.append(q("sqrt", bits_of(-f)))
    for k in range(1, 1000, 7):
        lines.append(q("sqrt", bits_of(float(k * k))))
        lines.append(q("sqrt", bits_of(float(k * k + 1))))
        lines.append(q("sqrt", bits_of(float(k * k - 1))))
    for i in range(0, 256, 5):
        lines.append(q("sqrt", make(0, i, 0)))
        lines.append(q("sqrt", make(0, i, 0x7FFFFF)))
        lines.append(q("sqrt", make(0, i, 0x400000)))
    t.append(("sqrt_known", lines))

    lines = []
    for e_gap in [0, 1, 2, 22, 23, 24, 25, 26, 27, 30, 48, 49, 50, 51, 52, 53, 54, 60, 100, 150, 200, 253, 254, 276, 277]:
        for ma in [0x800000, 0x800001, 0xFFFFFF, 0xC00000, 0xAAAAAA, 0x800002]:
            for mb in [0x800000, 0x800001, 0xFFFFFF, 0x955555]:
                ea = 0
                eb = -e_gap
                if ea + 23 + 127 > 254 or eb - 23 < -149:
                    ea = min(127, 100)
                    eb = ea - e_gap
                a = pack_exact(0, ma, ea)
                b = ref.round_pack(0, mb, eb)
                lines += [q("add", a, b), q("sub", a, b), q("add", neg(a), b), q("sub", b, a), q("add", b, neg(a))]
    t.append(("add_exponent_gaps", lines))

    lines = []
    for ea in [-149, -148, -127, -126, -125, -24, -1, 0, 1, 23, 24, 100, 104, 127]:
        for eb in [-149, -126, -50, -24, -23, -1, 0, 1, 24, 50, 127]:
            for ma, mb in [(0x800000, 0x800000), (0xFFFFFF, 0xFFFFFF), (0x800001, 0xFFFFFF), (0xB504F3, 0xB504F3), (1, 0xFFFFFF), (0x7FFFFF, 3)]:
                a = ref.round_pack(0, ma, ea - 23)
                b = ref.round_pack(0, mb, eb - 23)
                lines += [q("mul", a, b), q("div", a, b), q("div", b, a), q("mul", neg(a), b)]
    t.append(("mul_div_exponent_grid", lines))

    return t


# --------------------------------------------------------------------------
# Random generators
# --------------------------------------------------------------------------

def rand_bits(rng):
    return rng.getrandbits(32)


def rand_normal(rng, emin=1, emax=254):
    return make(rng.getrandbits(1), rng.randint(emin, emax), rng.getrandbits(23))


def rand_denormal(rng):
    return make(rng.getrandbits(1), 0, rng.randint(1, 0x7FFFFF))


def rand_special(rng):
    return rng.choice(SPECIALS + [rand_denormal(rng), make(rng.getrandbits(1), 255, rng.getrandbits(23)),
                                  make(rng.getrandbits(1), 254, rng.getrandbits(23)), make(rng.getrandbits(1), 1, rng.getrandbits(23))])


def rand_near(rng):
    """Operands whose exponents are close, so add/sub cancel and mul/div are near 1."""
    e = rng.randint(1, 254)
    a = make(rng.getrandbits(1), e, rng.getrandbits(23))
    e2 = min(254, max(1, e + rng.randint(-2, 2)))
    if rng.random() < 0.5:
        b = make(rng.getrandbits(1), e2, (a & 0x7FFFFF) ^ rng.getrandbits(rng.randint(0, 6)))
    else:
        b = make(rng.getrandbits(1), e2, rng.getrandbits(23))
    return a, b


def rand_tie_pair(rng, op):
    """Operand pair whose exact result lies on a rounding midpoint."""
    if op == "mul":
        while True:
            p = (1 << 24) | (rng.getrandbits(23) << 1) | 1
            d = rng.randint(3, 1 << 11)
            if p % d == 0:
                f1, f2 = d, p // d
                break
        ea = rng.randint(-100, 100)
        eb = rng.randint(-100, 100)
        return pack_exact(rng.getrandbits(1), f1, ea), pack_exact(rng.getrandbits(1), f2, eb)
    if op == "div":
        # Quotients in the denormal range: a = odd * 2**-149 style values divided by a power of two.
        a = make(rng.getrandbits(1), 0, rng.randint(1, 0x7FFFFF))
        b = make(rng.getrandbits(1), 127 + rng.randint(1, 30), 0)
        return a, b
    # add / sub: b is an odd multiple of a half ulp (or smaller power) of a.
    e = rng.randint(2, 254)
    a = make(rng.getrandbits(1), e, rng.getrandbits(23))
    lsb = e - 127 - 23
    k = rng.randint(1, 4)
    odd = (rng.getrandbits(rng.randint(0, 20)) << 1) | 1
    b = ref.round_pack(rng.getrandbits(1), odd, lsb - k)
    return a, b


def random_lines(rng, count, kinds, ops=ALL_OPS):
    lines = []
    for _ in range(count):
        op = rng.choice(ops)
        kind = rng.choice(kinds)
        if kind == "bits":
            a, b = rand_bits(rng), rand_bits(rng)
        elif kind == "normal":
            a, b = rand_normal(rng), rand_normal(rng)
        elif kind == "moderate":
            a, b = rand_normal(rng, 90, 165), rand_normal(rng, 90, 165)
        elif kind == "denormal":
            a, b = rand_denormal(rng), rand_denormal(rng)
        elif kind == "mixed_denormal":
            a, b = rand_denormal(rng), rand_normal(rng)
            if rng.random() < 0.5:
                a, b = b, a
        elif kind == "special":
            a, b = rand_special(rng), rand_bits(rng)
            if rng.random() < 0.5:
                a, b = b, a
        elif kind == "near":
            a, b = rand_near(rng)
        elif kind == "tie":
            a, b = rand_tie_pair(rng, op)
        else:
            raise ValueError(kind)
        lines.append(q(op, a) if op == "sqrt" else q(op, a, b))
    return lines


def generated():
    t = []
    rng = random.Random(1)
    t.append(("random_tiny", random_lines(rng, 100, ["bits", "normal"])))
    rng = random.Random(2)
    t.append(("random_small", random_lines(rng, 1000, ["bits", "normal", "special", "near"])))
    rng = random.Random(3)
    t.append(("random_add_sub", random_lines(rng, 10000, ["normal", "near", "moderate", "bits", "tie"], ["add", "sub"])))
    rng = random.Random(4)
    t.append(("random_mul_div", random_lines(rng, 10000, ["normal", "near", "moderate", "bits", "tie"], ["mul", "div"])))
    rng = random.Random(5)
    t.append(("random_sqrt", random_lines(rng, 10000, ["bits", "normal", "denormal", "special"], ["sqrt"])))
    rng = random.Random(6)
    t.append(("random_denormal_heavy", random_lines(rng, 20000, ["denormal", "mixed_denormal", "tie", "special"])))
    rng = random.Random(7)
    t.append(("random_special_heavy", random_lines(rng, 20000, ["special", "bits"])))
    rng = random.Random(8)
    t.append(("random_ties", random_lines(rng, 20000, ["tie"], BIN_OPS)))
    for i, seed in enumerate([101, 102, 103], start=1):
        rng = random.Random(seed)
        t.append(("random_large_%d" % i, random_lines(rng, 50000, ["bits", "normal", "moderate", "denormal", "mixed_denormal", "special", "near", "tie"])))
    rng = random.Random(104)
    t.append(("random_huge", random_lines(rng, 100000, ["bits", "normal", "moderate", "denormal", "mixed_denormal", "special", "near", "tie"])))
    return t


# --------------------------------------------------------------------------
# Host-FPU cross-check
# --------------------------------------------------------------------------

def to_float(bits):
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def host_result(op, a, b):
    """binary32 bit pattern the host FPU gives, or None where the spec's own
    special-case rules apply (NaN operands, x/0, sqrt of a negative)."""
    fa = to_float(a)
    if math.isnan(fa):
        return None
    if op == "sqrt":
        if fa < 0:
            return None
        r = math.sqrt(fa)
    else:
        fb = to_float(b)
        if math.isnan(fb):
            return None
        if op == "add":
            r = fa + fb
        elif op == "sub":
            r = fa - fb
        elif op == "mul":
            r = fa * fb
        else:
            if fb == 0:
                return None
            r = fa / fb
    if math.isnan(r):
        return QNAN
    try:
        return struct.unpack(">I", struct.pack(">f", r))[0]
    except OverflowError:
        return NEG_INF if r < 0 else POS_INF


def cross_check(lines, outputs):
    checked = 0
    for line, out in zip(lines, outputs):
        parts = line.split()
        op = parts[0]
        a = int(parts[1], 16)
        b = int(parts[2], 16) if len(parts) > 2 else None
        h = host_result(op, a, b)
        if h is None:
            continue
        checked += 1
        if h != int(out, 16):
            raise AssertionError("host disagrees on %r: reference %s host %08x" % (line, out, h))
    return checked


# --------------------------------------------------------------------------

def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.unlink(os.path.join(TESTS, f))
    cases = handwritten() + generated()
    total_checked = total_lines = 0
    for i, case in enumerate(cases, start=1):
        name, lines = case[0], case[1]
        trailing_newline = case[2] if len(case) > 2 else True
        base = os.path.join(TESTS, "%03d_%s" % (i, name))
        data = "\n".join(lines) + ("\n" if trailing_newline else "")
        with open(base + ".in", "w") as f:
            f.write(data)
        proc = subprocess.run([sys.executable, REF], input=data, capture_output=True, text=True, check=True)
        with open(base + ".out", "w") as f:
            f.write(proc.stdout)
        outputs = proc.stdout.split()
        assert len(outputs) == len(lines), name
        total_checked += cross_check(lines, outputs)
        total_lines += len(lines)
        print("%03d_%s: %d lines" % (i, name, len(lines)))
    print("cross-checked %d of %d results against the host FPU" % (total_checked, total_lines))


if __name__ == "__main__":
    main()
