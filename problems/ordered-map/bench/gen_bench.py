#!/usr/bin/env python3
"""Generate the ordered-map performance benchmark inputs and expected outputs.

Each input is as heavy as SPEC.md allows: Q = 200 000 commands, keys up to
the full i64 range, and (for the range workload) close to the 2 000 000
range-output cap. Inputs are deterministic (fixed seeds) and use the same
simulator as gen_tests.py, so every command is valid and steered towards
present keys and near misses. Expected outputs come from reference/main.py.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
sys.dont_write_bytecode = True

from gen_tests import MIXED, RANGE_OUTPUT_CAP, Workload, check_limits  # noqa: E402

REF = os.path.join(PROBLEM, "reference", "main.py")
Q = 200_000

ORDER_STATS = {"insert": 12, "delete": 8, "rank": 22, "select": 22, "floor": 8, "ceil": 8,
               "succ": 7, "pred": 7, "get": 4, "size": 1, "min": 1, "max": 1}
RANGE_SCAN = {"insert": 22, "delete": 10, "range": 50, "get": 6, "succ": 4, "pred": 4,
              "rank": 2, "size": 1, "min": 1}


def fill(w, weights, range_width):
    """Append random ops until exactly Q commands exist (a rejected range
    appends nothing, so count commands rather than iterations)."""
    while len(w.cmds) < Q:
        w.random_op(weights, range_width)
    return w.text()


def gen_build_mixed(seed):
    """Bulk-load 120k random keys in +-1e15 (16-digit), then 80k general mixed operations."""
    w = Workload(random.Random(seed), -10**15, 10**15)
    for _ in range(120_000):
        w.insert(w.rand_key())
    w.simple("size")
    return fill(w, MIXED, 12)


def gen_order_stats(seed):
    """Build 90k keys, then 110k rank/select/neighbour queries interleaved
    with inserts and deletes so subtree sizes are maintained throughout."""
    w = Workload(random.Random(seed), -10**12, 10**12)
    for _ in range(90_000):
        w.insert(w.rand_key())
    w.simple("size")
    return fill(w, ORDER_STATS, 10)


def gen_range_scan(seed):
    """Build 80k keys, then a range-dominated phase whose windows average ~24
    keys (about 1.3M keys printed in total, under the 2M-key cap)."""
    w = Workload(random.Random(seed), 0, 999_999)
    for _ in range(80_000):
        w.insert(w.rand_key())
    w.simple("size")
    return fill(w, RANGE_SCAN, 48)


BENCHES = {
    "001_bulk_build_mixed_200k": lambda: gen_build_mixed(101),
    "002_order_statistics_200k": lambda: gen_order_stats(102),
    "003_range_scan_heavy_200k": lambda: gen_range_scan(103),
}


def main():
    for f in os.listdir(HERE):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(HERE, f))
    for name, gen in BENCHES.items():
        text = gen()
        range_out = check_limits(name, text)
        data = text.encode()
        with open(os.path.join(HERE, name + ".in"), "wb") as f:
            f.write(data)
        res = subprocess.run([sys.executable, REF], input=data, capture_output=True, check=True)
        with open(os.path.join(HERE, name + ".out"), "wb") as f:
            f.write(res.stdout)
        print("%-32s %9d in %9d out  range keys %d (cap %d)"
              % (name, len(data), len(res.stdout), range_out, RANGE_OUTPUT_CAP))


if __name__ == "__main__":
    main()
