#!/usr/bin/env python3
"""Generate the bigint performance benchmark inputs deterministically.

Writes bench/NNN_name.in (same layout as tests/) and bench/NNN_name.out via
reference/main.py. Every input respects the SPEC limits: at most 10,000
queries, at most 8 MB, operands of at most 50,000 digits, exponents at most
5000, and every result at most 100,000 digits.
"""
import math
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)

sys.dont_write_bytecode = True
from gen_tests import q, rand_digits  # noqa: E402

if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

REF = os.path.join(PROBLEM, "reference", "main.py")
MAX_BYTES = 8_000_000
MIXED_BYTES = 4_000_000


def signed(rng, s):
    return "-" + s if rng.random() < 0.5 else s


def log_uniform(rng, lo, hi):
    return int(round(math.exp(rng.uniform(math.log(lo), math.log(hi)))))


def mul_large(seed=7001, reps=1):
    """Large products of assorted shapes: square, unbalanced, and medium."""
    rng = random.Random(seed)
    lines = []
    for _ in range(reps):
        lines.extend(mul_large_block(rng))
    rng.shuffle(lines)
    return lines


def mul_large_block(rng):
    lines = []
    for _ in range(6):
        lines.append(q(signed(rng, rand_digits(rng, rng.randint(45000, 50000))), "*",
                       signed(rng, rand_digits(rng, rng.randint(45000, 50000)))))
    for _ in range(10):
        lines.append(q(signed(rng, rand_digits(rng, rng.randint(25000, 35000))), "*",
                       signed(rng, rand_digits(rng, rng.randint(25000, 35000)))))
    for _ in range(16):
        lines.append(q(signed(rng, rand_digits(rng, rng.randint(40000, 50000))), "*",
                       signed(rng, rand_digits(rng, rng.randint(2000, 8000)))))
    for _ in range(40):
        lines.append(q(signed(rng, rand_digits(rng, rng.randint(5000, 15000))), "*",
                       signed(rng, rand_digits(rng, rng.randint(5000, 15000)))))
    return lines


def divmod_large(seed=7002, reps=1):
    """Long division of 30k-50k digit dividends by divisors of every size class."""
    rng = random.Random(seed)
    lines = []
    for _ in range(reps):
        lines.extend(divmod_large_block(rng))
    rng.shuffle(lines)
    return lines


def divmod_large_block(rng):
    lines = []

    def pair(a, d):
        sa, sd = rng.choice((1, -1)), rng.choice((1, -1))
        lines.append(q(sa * a, "/", sd * d))
        lines.append(q(sa * a, "%", sd * d))

    for _ in range(12):  # balanced: quotient and divisor both ~25k digits
        pair(int(rand_digits(rng, rng.randint(45000, 50000))), int(rand_digits(rng, rng.randint(20000, 25000))))
    for _ in range(8):  # long quotient, medium divisor
        pair(int(rand_digits(rng, rng.randint(40000, 50000))), int(rand_digits(rng, rng.randint(5000, 12000))))
    for _ in range(8):  # short quotient, divisor nearly as long as the dividend
        pair(int(rand_digits(rng, rng.randint(40000, 50000))), int(rand_digits(rng, rng.randint(35000, 39000))))
    for _ in range(6):  # small divisor (single or double limb)
        pair(int(rand_digits(rng, rng.randint(40000, 50000))), int(rand_digits(rng, rng.randint(1, 18))))
    for _ in range(6):  # exact-ish dividends q*d + r: quotient with zero runs
        d = int(rand_digits(rng, rng.randint(10000, 20000)))
        qv = int(rand_digits(rng, rng.randint(100, 5000))) * 10 ** rng.randint(1000, 15000)
        r = rng.randint(0, 1000)
        a = qv * d + r
        if len(str(a)) <= 50000:
            pair(a, d)
    return lines


def mixed_workload(seed=7003, max_bytes=MIXED_BYTES, max_queries=10000):
    """A calculator-style stream of every operation with log-uniform operand sizes."""
    rng = random.Random(seed)
    lines = []
    size = 0
    while len(lines) < max_queries:
        r = rng.random()
        if r < 0.30:
            op = rng.choice("+-")
            a = signed(rng, rand_digits(rng, log_uniform(rng, 1, 12000)))
            b = signed(rng, rand_digits(rng, log_uniform(rng, 1, 12000)))
        elif r < 0.55:
            op = "*"
            a = signed(rng, rand_digits(rng, log_uniform(rng, 1, 12000)))
            b = signed(rng, rand_digits(rng, log_uniform(rng, 1, 12000)))
        elif r < 0.75:
            op = rng.choice("/%")
            na = log_uniform(rng, 1, 12000)
            a = signed(rng, rand_digits(rng, na))
            b = signed(rng, rand_digits(rng, log_uniform(rng, 1, max(1, na))))
            if rng.random() < 0.01:
                b = "0"
        elif r < 0.82:
            op = "^"
            bd = log_uniform(rng, 1, 60)
            a = signed(rng, rand_digits(rng, bd))
            b = str(rng.randint(0, min(5000, 99000 // bd)))
            if rng.random() < 0.01:
                b = "-" + str(rng.randint(1, 100))
        else:
            op = "cmp"
            n = log_uniform(rng, 1, 12000)
            a = rand_digits(rng, n)
            b = a if rng.random() < 0.5 else rand_digits(rng, n)
            a, b = signed(rng, a), signed(rng, b)
        line = q(a, op, b)
        if size + len(line) + 1 > max_bytes:
            break
        lines.append(line)
        size += len(line) + 1
    return lines


# Long tier (../bench-long): the same three query mixes with more queries
# (repeated blocks for 001/002, a longer stream for 003). Operand and result
# sizes stay inside the usual limits; only the file size exceeds 8 MB.
LONG_DIR = os.path.join(PROBLEM, "bench-long")
LONG_MAX_BYTES = 40_000_000
LONG_MAX_QUERIES = 10_000


def long_cases():
    return [("mul_large", mul_large(seed=17001, reps=9)),
            ("divmod_large", divmod_large(seed=17002, reps=7)),
            ("mixed_workload", mixed_workload(seed=17003, max_bytes=20_000_000, max_queries=LONG_MAX_QUERIES))]


def main():
    long = "--long" in sys.argv[1:]
    if long:
        out_dir, max_bytes, max_queries = LONG_DIR, LONG_MAX_BYTES, LONG_MAX_QUERIES
        os.makedirs(out_dir, exist_ok=True)
        cases = long_cases()
    else:
        out_dir, max_bytes, max_queries = HERE, MAX_BYTES, 10000
        cases = [("mul_large", mul_large()), ("divmod_large", divmod_large()), ("mixed_workload", mixed_workload())]
    for f in os.listdir(out_dir):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(out_dir, f))
    for i, (name, lines) in enumerate(cases, start=1):
        assert len(lines) <= max_queries
        data = "\n".join(lines) + "\n"
        assert len(data) <= max_bytes, (name, len(data))
        base = os.path.join(out_dir, f"{i:03d}_{name}")
        with open(base + ".in", "w") as f:
            f.write(data)
        if "--no-ref" in sys.argv[1:]:
            print(f"{i:03d}_{name}: {len(lines)} queries, {len(data)} in (no output)")
            continue
        res = subprocess.run([sys.executable, REF], input=data.encode(), capture_output=True, check=True)
        for out in res.stdout.split(b"\n"):
            assert len(out.lstrip(b"-")) <= 100000, (name, len(out))
        with open(base + ".out", "wb") as f:
            f.write(res.stdout)
        print(f"{i:03d}_{name}: {len(lines)} queries, {len(data)} in, {len(res.stdout)} out")


if __name__ == "__main__":
    main()
