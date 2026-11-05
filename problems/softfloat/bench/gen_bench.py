#!/usr/bin/env python3
"""Generate the softfloat performance benchmark inputs deterministically.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py softfloat --tests-dir problems/softfloat/bench` works. Each
input uses the spec's maximum of 100,000 lines. Expected outputs come from the
Python reference and are cross-checked against the host FPU (see gen_tests.py).
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, "reference", "main.py")
sys.dont_write_bytecode = True
sys.path.insert(0, PROBLEM)
import gen_tests as gt  # noqa: E402

LINES = 100_000  # the spec's per-file maximum


def numeric_throughput(rng):
    """Ordinary numeric work: normal operands of moderate magnitude, all five ops."""
    ops = ["add"] * 3 + ["sub"] * 2 + ["mul"] * 3 + ["div", "sqrt"]
    lines = []
    for _ in range(LINES):
        op = rng.choice(ops)
        kind = rng.choice(["moderate", "moderate", "normal", "near"])
        lines += gt.random_lines(rng, 1, [kind], [op])
    return lines


def div_sqrt_heavy(rng):
    """Only div and sqrt, the bit-serial / long-division paths, including
    denormal operands (which need normalisation) and denormal-range quotients."""
    lines = []
    for _ in range(LINES):
        op = "div" if rng.random() < 0.6 else "sqrt"
        kind = rng.choice(["normal", "normal", "moderate", "near", "mixed_denormal", "denormal", "tie", "bits"])
        if op == "sqrt" and kind == "tie":
            kind = "normal"
        lines += gt.random_lines(rng, 1, [kind], [op])
    return lines


def mixed_realistic(rng):
    """Everything at once: all ops and all operand classes, as in the largest
    public test but with a different seed and weighting."""
    kinds = ["bits", "normal", "normal", "moderate", "moderate", "denormal", "mixed_denormal",
             "special", "near", "near", "tie"]
    return gt.random_lines(rng, LINES, kinds)


CASES = [
    ("numeric_throughput", numeric_throughput, 9001),
    ("div_sqrt_heavy", div_sqrt_heavy, 9002),
    ("mixed_realistic", mixed_realistic, 9003),
]


def main():
    for f in os.listdir(HERE):
        if f.endswith(".in") or f.endswith(".out"):
            os.unlink(os.path.join(HERE, f))
    for i, (name, fn, seed) in enumerate(CASES, start=1):
        lines = fn(random.Random(seed))
        assert len(lines) == LINES
        data = "\n".join(lines) + "\n"
        base = os.path.join(HERE, "%03d_%s" % (i, name))
        with open(base + ".in", "w") as f:
            f.write(data)
        proc = subprocess.run([sys.executable, REF], input=data, capture_output=True, text=True, check=True)
        outputs = proc.stdout.split()
        assert len(outputs) == LINES, name
        checked = gt.cross_check(lines, outputs)
        with open(base + ".out", "w") as f:
            f.write(proc.stdout)
        print("%03d_%s: %d lines, %d host-checked" % (i, name, LINES, checked))


if __name__ == "__main__":
    main()
