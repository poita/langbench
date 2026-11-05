#!/usr/bin/env python3
"""Generate tests/*.in deterministically and tests/*.out via reference/main.py.

Hand-written edge cases are embedded as literals. Generated workloads come
from a small simulator (sorted list + dict) that tracks the live key set so
commands can target present keys, near-miss keys and exact neighbours, and so
the total range output stays under the cap promised in SPEC.md.
"""
import os
import random
import subprocess
import sys
from bisect import bisect_left, bisect_right

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")

I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1
RANGE_OUTPUT_CAP = 2_000_000

VALUE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:/!#$%&*+=?@^~"


def rand_value(rng, lo=1, hi=5):
    return "".join(rng.choice(VALUE_CHARS) for _ in range(rng.randint(lo, hi)))


class Workload:
    """Builds a command list while simulating the map to steer key choices."""

    def __init__(self, rng, kmin, kmax):
        self.rng = rng
        self.kmin = kmin
        self.kmax = kmax
        self.keys = []
        self.present = set()
        self.cmds = []
        self.range_output = 0

    # --- key pickers -----------------------------------------------------
    def rand_key(self):
        return self.rng.randint(self.kmin, self.kmax)

    def present_key(self):
        return self.rng.choice(self.keys) if self.keys else self.rand_key()

    def near_key(self):
        """A key adjacent to a present one (usually absent), clamped to i64."""
        if not self.keys:
            return self.rand_key()
        k = self.rng.choice(self.keys) + self.rng.choice((-2, -1, 1, 2))
        return max(I64_MIN, min(I64_MAX, k))

    def query_key(self):
        r = self.rng.random()
        if r < 0.4:
            return self.present_key()
        if r < 0.7:
            return self.near_key()
        if r < 0.75:
            return self.rng.choice((I64_MIN, I64_MAX, self.kmin, self.kmax, 0))
        return self.rand_key()

    # --- mutators --------------------------------------------------------
    def insert(self, k, v=None):
        if v is None:
            v = rand_value(self.rng)
        self.cmds.append("insert %d %s" % (k, v))
        if k not in self.present:
            self.present.add(k)
            self.keys.insert(bisect_left(self.keys, k), k)

    def delete(self, k):
        self.cmds.append("delete %d" % k)
        if k in self.present:
            self.present.discard(k)
            del self.keys[bisect_left(self.keys, k)]

    def range(self, lo, hi):
        n = bisect_right(self.keys, hi) - bisect_left(self.keys, lo)
        if self.range_output + max(n, 0) > RANGE_OUTPUT_CAP:
            return False
        self.range_output += max(n, 0)
        self.cmds.append("range %d %d" % (lo, hi))
        return True

    def range_window(self, max_out):
        """A range around a present key sized to emit at most max_out keys."""
        if not self.keys or max_out <= 0:
            return self.range(self.rand_key(), self.rand_key())
        i = self.rng.randrange(len(self.keys))
        w = self.rng.randint(0, max_out - 1)
        j = min(len(self.keys) - 1, i + w)
        lo = self.keys[i] - self.rng.randint(0, 3)
        hi = self.keys[j] + self.rng.randint(0, 3)
        return self.range(max(I64_MIN, lo), min(I64_MAX, hi))

    def query(self, name, k):
        self.cmds.append("%s %d" % (name, k))

    def simple(self, name):
        self.cmds.append(name)

    def select_arg(self):
        n = len(self.keys)
        r = self.rng.random()
        if n and r < 0.8:
            return self.rng.randrange(n)
        if r < 0.9:
            return n  # exactly one past the end
        return self.rng.randint(0, n + 5)

    # --- random step -------------------------------------------------------
    def random_op(self, weights, range_width=20):
        op = self.rng.choices(list(weights), weights=list(weights.values()))[0]
        if op == "insert":
            self.insert(self.present_key() if self.rng.random() < 0.15 else self.rand_key())
        elif op == "delete":
            self.delete(self.present_key() if self.rng.random() < 0.7 else self.query_key())
        elif op in ("size", "min", "max"):
            self.simple(op)
        elif op == "select":
            self.query("select", self.select_arg())
        elif op == "range":
            if self.rng.random() < 0.05:
                a, b = self.rand_key(), self.rand_key()
                self.range(max(a, b), min(a, b))  # lo > hi unless equal
            else:
                self.range_window(range_width)
        else:
            self.query(op, self.query_key())

    def text(self):
        return "%d\n%s" % (len(self.cmds), "\n".join(self.cmds) + ("\n" if self.cmds else ""))


MIXED = {"insert": 30, "delete": 12, "get": 12, "floor": 6, "ceil": 6, "succ": 5,
         "pred": 5, "rank": 6, "select": 6, "range": 4, "size": 3, "min": 2, "max": 2}
RANK_SELECT = {"insert": 22, "delete": 12, "rank": 25, "select": 25, "get": 4,
               "floor": 3, "ceil": 3, "size": 4, "min": 1, "max": 1}
RANGE_HEAVY = {"insert": 25, "delete": 10, "range": 45, "get": 5, "succ": 5, "pred": 5,
               "size": 3, "min": 1, "max": 1}
QUERY_ONLY = {"get": 15, "floor": 12, "ceil": 12, "succ": 12, "pred": 12, "rank": 12,
              "select": 12, "range": 5, "size": 3, "min": 3, "max": 2}


def lit(cmds):
    return "%d\n%s\n" % (len(cmds), "\n".join(cmds))


# ---------------------------------------------------------------------------
# Hand-written edge cases
# ---------------------------------------------------------------------------

def hand_tests():
    t = {}
    t["001_empty_map"] = lit([
        "size", "min", "max", "get 0", "delete 0", "floor 5", "ceil 5", "succ 5",
        "pred 5", "rank 5", "rank -9223372036854775808", "select 0", "select 1",
        "range -5 5", "range 5 -5", "range -9223372036854775808 9223372036854775807",
        "size",
    ])
    t["002_zero_commands"] = "0\n"
    t["003_single_key"] = lit([
        "insert 7 seven", "size", "min", "max", "get 7", "get 6", "get 8",
        "floor 7", "floor 8", "floor 6", "ceil 7", "ceil 6", "ceil 8",
        "succ 7", "succ 6", "succ 8", "pred 7", "pred 8", "pred 6",
        "rank 6", "rank 7", "rank 8", "select 0", "select 1",
        "range 7 7", "range 6 8", "range 8 9", "range 5 6", "range 8 6",
        "delete 7", "size", "min", "max", "get 7", "delete 7",
    ])
    t["004_insert_update"] = lit([
        "insert 1 a", "insert 1 b", "insert 1 c", "get 1", "size",
        "insert 2 x", "insert 2 x", "get 2", "size", "delete 1", "insert 1 d",
        "get 1", "size", "range 1 2",
    ])
    t["005_delete_reinsert_churn"] = lit([
        "delete 42", "insert 42 v1", "delete 42", "delete 42", "insert 42 v2",
        "insert 42 v3", "get 42", "delete 42", "get 42", "size", "insert 42 v4",
        "get 42", "size", "min", "max", "rank 42", "rank 43", "select 0",
        "delete 42", "select 0", "min",
    ])
    # Delete the min five times, then the max five times.
    cmds = ["insert %d k%d" % (k, k) for k in (5, 3, 8, 1, 9, 2, 7, 4, 6, 10)]
    cmds += ["size", "min", "max"]
    for k in (1, 2, 3, 4, 5):
        cmds += ["delete %d" % k, "min", "size"]
    for k in (10, 9, 8, 7, 6):
        cmds += ["delete %d" % k, "max", "size"]
    cmds += ["min", "max", "select 0", "rank 100", "range 1 10"]
    t["006_min_max_deletion"] = lit(cmds)
    cmds = ["insert %d v%d" % (k, k) for k in (10, 20, 30, 40)]
    for k in (5, 10, 15, 20, 25, 30, 35, 40, 45):
        cmds += ["floor %d" % k, "ceil %d" % k]
    cmds += ["delete 20", "floor 20", "ceil 20", "floor 25", "ceil 15", "floor 29", "ceil 31"]
    t["007_floor_ceil"] = lit(cmds)
    cmds = ["insert %d v" % k for k in (-3, 0, 3)]
    for k in (-4, -3, -2, -1, 0, 1, 2, 3, 4):
        cmds += ["succ %d" % k, "pred %d" % k]
    cmds += ["delete 0", "succ -3", "pred 3", "succ -1", "pred 1", "delete -3", "delete 3",
             "succ 0", "pred 0"]
    t["008_succ_pred"] = lit(cmds)
    cmds = ["insert %d v" % k for k in (100, 200, 300, 400, 500)]
    for k in (99, 100, 101, 250, 500, 501, -1):
        cmds.append("rank %d" % k)
    for k in (0, 1, 2, 3, 4, 5, 6, 1000000000):
        cmds.append("select %d" % k)
    cmds += ["delete 300", "rank 300", "rank 301", "select 2", "select 3", "select 4",
             "insert 250 v", "select 2", "rank 250", "rank 251"]
    t["009_rank_select"] = lit(cmds)
    cmds = ["insert %d v" % k for k in (2, 4, 6, 8, 10)]
    cmds += ["range 2 10", "range 1 11", "range 4 4", "range 3 3", "range 5 5",
             "range 3 9", "range 4 8", "range 10 2", "range 11 20", "range -10 1",
             "range 2 2", "range 10 10", "range 9 10", "range 10 11", "range 6 5",
             "range 0 0", "range -9223372036854775808 9223372036854775807",
             "delete 6", "range 3 9", "range 6 6"]
    t["010_range"] = lit(cmds)
    cmds = [
        "insert 9223372036854775807 max", "insert -9223372036854775808 min",
        "insert 0 zero", "insert -1 neg1", "insert 1 pos1",
        "insert 9223372036854775806 maxm1", "insert -9223372036854775807 minp1",
        "size", "min", "max", "get 9223372036854775807", "get -9223372036854775808",
        "succ 9223372036854775807", "pred -9223372036854775808",
        "succ 9223372036854775806", "pred -9223372036854775807",
        "floor 9223372036854775807", "ceil -9223372036854775808",
        "floor -9223372036854775808", "ceil 9223372036854775807",
        "rank 9223372036854775807", "rank -9223372036854775808",
        "rank -9223372036854775807", "select 0", "select 6", "select 7",
        "range -9223372036854775808 -9223372036854775807",
        "range 9223372036854775806 9223372036854775807",
        "range -9223372036854775808 9223372036854775807",
        "range 9223372036854775807 9223372036854775807",
        "range -9223372036854775808 -9223372036854775808",
        "delete 9223372036854775807", "max", "succ 9223372036854775806",
        "ceil 9223372036854775807", "delete -9223372036854775808", "min",
        "pred -9223372036854775807", "floor -9223372036854775808",
        "insert 9223372036854775807 back", "get 9223372036854775807", "max",
    ]
    t["011_extreme_keys"] = lit(cmds)
    cmds = [
        "insert 1 missing", "insert 2 empty", "insert 3 ok", "insert 4 updated",
        "insert 5 !#$%&*+-./:=?@^_~", "insert 6 " + "x" * 32, "insert 7 0",
        "insert 8 -1", "insert 9 9223372036854775807", "insert 10 a",
        "get 1", "get 2", "get 3", "get 4", "get 5", "get 6", "get 7", "get 8",
        "get 9", "get 10", "get 11", "insert 10 b", "get 10", "insert 6 " + "y" * 32,
        "get 6", "delete 1", "get 1", "size",
    ]
    # Every printable ASCII character 0x21..0x7E appears in some value, split
    # into chunks of at most 32 characters, in both forward and reversed order
    # so quotes, backslashes, angle brackets and the like are stored verbatim.
    printable = "".join(chr(c) for c in range(0x21, 0x7F))
    chunks = [printable[i:i + 32] for i in range(0, len(printable), 32)]
    for i, ch in enumerate(chunks):
        cmds += ["insert %d %s" % (20 + i, ch), "get %d" % (20 + i)]
    for i, ch in enumerate(chunks):
        cmds += ["insert %d %s" % (20 + i, ch[::-1]), "get %d" % (20 + i)]
    cmds += ["insert 30 \\", "get 30", "insert 31 \"", "get 31", "insert 32 '", "get 32",
             "insert 33 \"'\\", "get 33", "size"]
    t["012_value_strings"] = lit(cmds)
    # The three SPEC.md worked examples, each as its own test so the expected
    # output must match the spec text verbatim (checked in main()).
    t["013_spec_example_1"] = lit([
        "size", "min", "insert 5 five", "insert 5 FIVE", "get 5", "insert 2 two",
        "insert 9 nine", "min", "max", "range 2 9", "delete 5", "range 3 8",
    ])
    t["013_spec_example_2"] = lit([
        "insert 10 a", "insert 20 b", "insert 30 c", "floor 25", "ceil 25", "floor 10",
        "ceil 10", "succ 10", "pred 10", "succ 30", "rank 20", "rank 21", "select 2",
        "select 3",
    ])
    # Deliberately no trailing newline after the last command.
    t["013_spec_example_3"] = lit([
        "insert -9223372036854775808 lo", "insert 9223372036854775807 hi", "insert 0 zero",
        "succ 9223372036854775807", "pred -9223372036854775808",
        "floor -9223372036854775807", "ceil 1",
        "range -9223372036854775808 9223372036854775807", "delete 0",
    ]).rstrip("\n")
    # Negative keys only, with a sequence that exercises every command on
    # negatives (a common sign-handling slip).
    cmds = ["insert %d n%d" % (k, -k) for k in (-50, -10, -30, -20, -40)]
    cmds += ["min", "max", "floor -25", "ceil -25", "succ -30", "pred -30", "rank -30",
             "rank -31", "select 0", "select 4", "range -45 -15", "range -100 -50",
             "delete -50", "min", "floor -49", "pred -40", "range -60 -45"]
    t["014_negative_keys"] = lit(cmds)
    return t


# ---------------------------------------------------------------------------
# Generated workloads
# ---------------------------------------------------------------------------

def gen_random(seed, n, kmin, kmax, weights, range_width=20):
    w = Workload(random.Random(seed), kmin, kmax)
    for _ in range(n):
        w.random_op(weights, range_width)
    return w.text()


def gen_sorted_insert(seed, n, descending=False, step=1, queries=True):
    """Insert n keys in sorted order, then a query pass, then delete in reverse."""
    rng = random.Random(seed)
    w = Workload(rng, -n * step, n * step)
    order = range(n) if not descending else range(n - 1, -1, -1)
    for i in order:
        w.insert(i * step)
    w.simple("size")
    w.simple("min")
    w.simple("max")
    if queries:
        for _ in range(n // 4):
            w.random_op(QUERY_ONLY, 10)
    # Delete in descending order (removes the max each time).
    for i in range(n - 1, -1, -1):
        w.delete(i * step)
        if i % 997 == 0:
            w.simple("max")
            w.simple("size")
    w.simple("size")
    w.simple("min")
    return w.text()


def gen_ascending_insert_descending_delete_interleaved(seed, n):
    """Keys arrive ascending while the map is drained from the top: after each
    block of inserts, the current maximum is removed a few times."""
    rng = random.Random(seed)
    w = Workload(rng, 0, 4 * n)
    k = 0
    while len(w.cmds) < n:
        for _ in range(8):
            w.insert(k)
            k += 1
        for _ in range(3):
            if w.keys:
                w.delete(w.keys[-1])
        w.query("select", w.select_arg())
        w.query("rank", w.query_key())
    return w.text()


def gen_zigzag(seed, n):
    """Alternately insert a new global min and a new global max, then drain by
    alternately deleting the min and the max."""
    rng = random.Random(seed)
    w = Workload(rng, -n, n)
    lo, hi = 0, 1
    for i in range(n // 2):
        if i % 2 == 0:
            w.insert(hi)
            hi += 1
        else:
            w.insert(lo)
            lo -= 1
    for _ in range(n // 8):
        w.random_op(QUERY_ONLY, 10)
    while w.keys:
        w.delete(w.keys[0])
        if w.keys:
            w.delete(w.keys[-1])
    w.simple("size")
    return w.text()


def gen_churn(seed, n, nkeys):
    """Repeatedly insert and delete the same small set of keys."""
    rng = random.Random(seed)
    w = Workload(rng, 0, nkeys - 1)
    for _ in range(n):
        r = rng.random()
        k = rng.randrange(nkeys)
        if r < 0.45:
            w.insert(k)
        elif r < 0.85:
            w.delete(k)
        elif r < 0.9:
            w.query("get", k)
        elif r < 0.95:
            w.query("rank", k)
        else:
            w.simple("size")
    return w.text()


def gen_extreme_random(seed, n):
    """Random ops with keys clustered at the i64 extremes and around zero."""
    rng = random.Random(seed)
    w = Workload(rng, I64_MIN, I64_MAX)
    orig = w.rand_key

    def rand_key():
        r = rng.random()
        if r < 0.3:
            return I64_MIN + rng.randint(0, 50)
        if r < 0.6:
            return I64_MAX - rng.randint(0, 50)
        if r < 0.8:
            return rng.randint(-50, 50)
        return orig()

    w.rand_key = rand_key
    for _ in range(n):
        w.random_op(MIXED, 10)
    return w.text()


def gen_build_then_query(seed, nkeys, nq, kmin, kmax, weights, range_width):
    """Bulk random build followed by a long query-dominated phase."""
    rng = random.Random(seed)
    w = Workload(rng, kmin, kmax)
    for _ in range(nkeys):
        w.insert(w.rand_key())
    w.simple("size")
    for _ in range(nq):
        w.random_op(weights, range_width)
    return w.text()


def gen_large_ranges(seed, nkeys, nwide, kmin, kmax):
    """Wide range walks: after a random build, emit ranges covering thousands
    of keys each (including the whole map, both by exact min/max and by the
    i64 extremes), with mutations between walks so the structure changes."""
    rng = random.Random(seed)
    w = Workload(rng, kmin, kmax)
    for _ in range(nkeys):
        w.insert(w.rand_key())
    w.simple("size")
    w.range(I64_MIN, I64_MAX)
    w.range(w.keys[0], w.keys[-1])
    w.range(w.keys[0] + 1, w.keys[-1] - 1)
    w.range(kmin, kmax)
    for _ in range(nwide):
        n = len(w.keys)
        i = rng.randrange(n)
        j = min(n - 1, i + rng.randint(n // 4, n))
        lo = w.keys[i] - rng.randint(0, 2)
        hi = w.keys[j] + rng.randint(0, 2)
        w.range(lo, hi)
        for _ in range(rng.randint(20, 200)):
            w.random_op(MIXED, 10)
    w.range(I64_MIN, I64_MAX)
    w.simple("size")
    return w.text()


def generated_tests():
    t = {}
    t["015_random_tiny_dense"] = gen_random(1, 300, -10, 10, MIXED, 5)
    t["016_random_small_dense"] = gen_random(2, 2000, -60, 60, MIXED, 10)
    t["017_random_small_wide"] = gen_random(3, 2000, I64_MIN, I64_MAX, MIXED, 10)
    t["018_random_medium"] = gen_random(4, 20000, -5000, 5000, MIXED, 20)
    t["019_rank_select_medium"] = gen_random(5, 20000, -100000, 100000, RANK_SELECT)
    t["020_range_medium"] = gen_random(6, 10000, -3000, 3000, RANGE_HEAVY, 25)
    t["021_churn_small_keyset"] = gen_churn(7, 30000, 64)
    t["022_sorted_insert_30k"] = gen_sorted_insert(8, 30000)
    t["023_descending_insert_30k"] = gen_sorted_insert(9, 30000, descending=True, step=3)
    t["024_zigzag_60k"] = gen_zigzag(10, 60000)
    t["025_interleaved_asc_desc_60k"] = gen_ascending_insert_descending_delete_interleaved(11, 60000)
    t["026_extreme_keys_random_40k"] = gen_extreme_random(12, 40000)
    t["027_random_200k_wide"] = gen_random(13, 200000, I64_MIN, I64_MAX, MIXED, 8)
    t["028_random_200k_dense"] = gen_random(14, 200000, -50000, 50000, MIXED, 12)
    t["029_sorted_insert_100k_delete_desc"] = gen_sorted_insert(15, 99800, queries=False)
    t["030_rank_select_200k"] = gen_build_then_query(16, 80000, 119999, -10**6, 10**6, RANK_SELECT, 10)
    t["031_range_heavy_200k"] = gen_build_then_query(17, 50000, 149999, -200000, 200000, RANGE_HEAVY, 8)
    t["032_wide_ranges_30k"] = gen_large_ranges(18, 30000, 30, -100000, 100000)
    return t


def check_limits(name, text):
    """Enforce the bounds promised in SPEC.md on every test, hand-written too."""
    lines = text.split("\n")
    q = int(lines[0])
    assert 0 <= q <= 200000, (name, q)
    cmds = lines[1:1 + q]
    assert len(cmds) == q, (name, len(cmds), q)
    keys = []
    range_out = 0
    for c in cmds:
        p = c.split(" ")
        for j, tok in enumerate(p[1:], 1):
            if p[0] == "insert" and j == 2:
                assert 1 <= len(tok) <= 32 and all(0x21 <= ord(ch) <= 0x7E for ch in tok), (name, c)
            else:
                v = int(tok)
                if p[0] == "select":
                    assert 0 <= v <= 10**9, (name, c)
                else:
                    assert I64_MIN <= v <= I64_MAX, (name, c)
                assert str(v) == tok, (name, c)
        if p[0] == "insert":
            k = int(p[1])
            i = bisect_left(keys, k)
            if i == len(keys) or keys[i] != k:
                keys.insert(i, k)
        elif p[0] == "delete":
            k = int(p[1])
            i = bisect_left(keys, k)
            if i < len(keys) and keys[i] == k:
                del keys[i]
        elif p[0] == "range":
            lo, hi = int(p[1]), int(p[2])
            range_out += max(0, bisect_right(keys, hi) - bisect_left(keys, lo))
    assert range_out <= RANGE_OUTPUT_CAP, (name, range_out)
    return range_out


def check_spec_example(name, inp, out):
    """Assert that SPEC.md contains this example's input and output blocks verbatim."""
    with open(os.path.join(HERE, "SPEC.md")) as f:
        spec = f.read()

    def block(text):
        return "\n".join("    " + ln for ln in text.strip("\n").split("\n"))

    assert block(inp) in spec, ("input block missing from SPEC.md", name)
    assert block(out) in spec, ("output block missing from SPEC.md", name)


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(TESTS, f))
    tests = {}
    tests.update(hand_tests())
    tests.update(generated_tests())
    total = 0
    for name in sorted(tests):
        data = tests[name].encode()
        check_limits(name, tests[name])
        in_path = os.path.join(TESTS, name + ".in")
        with open(in_path, "wb") as f:
            f.write(data)
        res = subprocess.run([sys.executable, REF], input=data, capture_output=True, check=True)
        with open(os.path.join(TESTS, name + ".out"), "wb") as f:
            f.write(res.stdout)
        total += len(data) + len(res.stdout)
        if name.startswith("013_spec_example_"):
            check_spec_example(name, data.decode(), res.stdout.decode())
        print("%-40s %9d in %9d out" % (name, len(data), len(res.stdout)))
    print("total bytes:", total)


if __name__ == "__main__":
    main()
