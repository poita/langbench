#!/usr/bin/env python3
"""Generate the performance benchmark inputs for `depresolve`.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py depresolve --tests-dir problems/depresolve/bench` works.
Every input is deterministic (fixed seeds), checked against the input grammar
and the limits in SPEC.md, and its expected output comes from
reference/main.py.

Usage: python3 gen_bench.py [--no-expected]
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, "reference", "main.py")
sys.path.insert(0, PROBLEM)

import gen_tests as g  # noqa: E402


def tree_rebuild(seed, npk, nver, fan, nroot, ntool, nrt, tool_ok, rt_ok):
    """A large lockfile-style registry (every range on a tree package matches
    exactly one version, so the tree itself never branches) whose root first
    chooses two unconstrained top-level packages, `toolchain` and `runtime`,
    then the tree, and last a `platform` package that only accepts the
    `tool_ok`-th newest toolchain and older, and the `rt_ok`-th newest
    runtime and older. Chronological backtracking therefore rebuilds and
    tears down the whole few-hundred-package tree once per rejected
    (toolchain, runtime) combination before the resolution succeeds."""
    r = random.Random(seed)
    names, vers = g.layered_names_versions(r, npk, nver)
    planted = {n: r.choice(vers[n]) for n in names}
    lines = []
    for i, n in enumerate(names):
        for v in vers[n]:
            cands = names[i + 1:]
            k = min(len(cands), r.randrange(1, fan + 1)) if cands else 0
            deps = r.sample(cands, k)
            parts = [f"{d} {g.range_only(r, vers[d], planted[d])}" for d in deps]
            lines.append(f"{n} {g.fmt(v)}:" + (" " + ", ".join(parts) if parts else ""))

    def top_versions(count):
        out, cur = [], (1, 0, 0)
        while len(out) < count:
            out.append(cur)
            cur = (cur[0], cur[1] + 1, 0) if r.random() < 0.6 else (cur[0] + 1, 0, 0)
        return out

    tool_vers = top_versions(ntool)
    rt_vers = top_versions(nrt)
    for name, vs in (("toolchain", tool_vers), ("runtime", rt_vers)):
        for v in vs:
            deps = r.sample(names[-100:], 3)
            parts = [f"{d} {g.range_only(r, vers[d], planted[d])}" for d in deps]
            lines.append(f"{name} {g.fmt(v)}: " + ", ".join(parts))
    tool_max = tool_vers[-tool_ok]
    rt_max = rt_vers[-rt_ok]
    lines.append(f"platform 1.0.0: toolchain <={g.fmt(tool_max)}, runtime <={g.fmt(rt_max)}")
    r.shuffle(lines)
    rootdeps = r.sample(names[:25], nroot)
    parts = ["toolchain *", "runtime *"]
    parts += [f"{d} {g.range_only(r, vers[d], planted[d])}" for d in rootdeps]
    parts.append("platform *")
    lines.append("root: " + ", ".join(parts))
    return "\n".join(lines) + "\n"


CASES = [
    # Large registry, long build/unwind cycles of a ~480-package tree.
    ("large_tree_rebuild", lambda: tree_rebuild(1101, 480, 20, 28, 10, 200, 60, 150, 1)),
    # Random registry with arbitrary ranges; heavy backtracking, then success.
    ("random150_sat_backtrack", lambda: g.random_registry(2097, 150, 10, 6, 4)),
    # Random registry with arbitrary ranges; exhaustive search proves failure.
    ("random100_unsat_exhaustive", lambda: g.random_registry(1009, 100, 8, 5, 4)),
]


# Long tier (bench-long/): the same three shapes with roughly 15-35x the
# search. 001 has more toolchain and runtime versions to reject (SPEC.md now
# allows 1600 versions of a package and 12,001 lines); 002 and 003 are random
# registries of the same shapes, with seeds picked for a long search.
LONG_CASES = [
    ("large_tree_rebuild", lambda: tree_rebuild(1101, 480, 20, 28, 10, 250, 1600, 200, 1)),
    ("random150_sat_backtrack", lambda: g.random_registry(SAT_SEED, *SAT_SHAPE)),
    ("random100_unsat_exhaustive", lambda: g.random_registry(UNSAT_SEED, *UNSAT_SHAPE)),
]
SAT_SEED, SAT_SHAPE = 4011, (150, 10, 6, 4)
UNSAT_SEED, UNSAT_SHAPE = 5041, (100, 8, 5, 4)
LIMITS = (3_000_000, 10_001, 250)
LONG_LIMITS = (3_000_000, 12_001, 1600)


def check_limits(text, limits=LIMITS):
    max_bytes, max_lines, max_versions = limits
    g.validate(text)
    lines = text.split("\n")[:-1]
    assert len(text.encode()) <= max_bytes, "input over size limit"
    assert len(lines) <= max_lines, "too many lines"
    pkgs = {}
    for line in lines[:-1]:
        head = line.split(":", 1)[0]
        name, _ = head.split(" ")
        pkgs[name] = pkgs.get(name, 0) + 1
    assert len(pkgs) <= 3000 and max(pkgs.values()) <= max_versions
    for line in lines:
        tail = line.split(":", 1)[1]
        assert (tail.count(", ") + 1 if tail else 0) <= 40


def main():
    want_expected = "--no-expected" not in sys.argv[1:]
    out_dir, cases, limits = HERE, CASES, LIMITS
    if "--long" in sys.argv[1:]:
        out_dir, cases, limits = os.path.join(PROBLEM, "bench-long"), LONG_CASES, LONG_LIMITS
        os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(out_dir, f))
    for idx, (name, make) in enumerate(cases, start=1):
        base = f"{idx:03d}_{name}"
        text = make()
        check_limits(text, limits)
        with open(os.path.join(out_dir, base + ".in"), "w") as f:
            f.write(text)
        msg = f"{base}: {len(text)} bytes, {text.count(chr(10))} lines"
        if want_expected:
            proc = subprocess.run([sys.executable, REF], input=text, capture_output=True,
                                  text=True, check=True)
            with open(os.path.join(out_dir, base + ".out"), "w") as f:
                f.write(proc.stdout)
            first = proc.stdout.split("\n")[0] if proc.stdout else "(empty)"
            msg += f" -> {first} ({proc.stdout.count(chr(10))} lines)"
        print(msg, flush=True)


if __name__ == "__main__":
    main()
