#!/usr/bin/env python3
"""Generate the performance benchmark inputs for the `diff` problem.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py diff --tests-dir problems/diff/bench` works. Inputs are
deterministic (fixed seeds) and stay within the SPEC limits (N, M <= 5000,
lines <= 200 code points, total input < 300 KB). Expected outputs come from
the reference implementation; for diff-mode inputs the reference's edit count
is cross-checked against the verifier's independent bit-parallel LCS.

With --long it writes the long tier to bench-long/ instead: the same three
cases with longer files (LONG_LINES) and proportionally more edits. Expected
outputs there also come from the reference, whose saved V arrays take O(D^2)
memory, so LONG_LINES is sized to keep it under about 4 GB; the expected
scripts are additionally checked to turn A into B.
"""
import argparse
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, "reference", "main.py")
sys.path.insert(0, PROBLEM)
from gen_tests import diff_input, patch_input  # noqa: E402
from verify import apply_script, lcs_length, parse_output  # noqa: E402

MAX_LINES = 5000
MAX_INPUT_BYTES = 300_000

IDENTS = ("count index buffer result value offset length state node item "
          "parent child cursor table entry source target config options error "
          "handle stream reader writer token scope frame queue cache limit").split()
TYPES = ("int", "size_t", "bool", "char *", "struct node *", "uint32_t", "double")
CALLS = ("memcpy", "strlen", "malloc", "free", "assert", "printf", "update",
         "insert", "lookup", "emit", "flush", "reset", "parse_token")


def code_line(rng, depth):
    """One line of C-like source at the given nesting depth. Structural lines
    ("}", "", "return 0;", "break;") recur constantly, as in real code, so
    files contain many duplicate lines and diffs have long equal snakes."""
    ind = "  " * depth
    r = rng.random()
    a, b, c = rng.choice(IDENTS), rng.choice(IDENTS), rng.choice(IDENTS)
    if r < 0.14:
        return ""
    if r < 0.26:
        return ind + "}"
    if r < 0.32:
        return ind + rng.choice(("return 0;", "break;", "continue;", "return -1;", "} else {"))
    if r < 0.48:
        return f"{ind}{rng.choice(TYPES)} {a} = {b}->{c} + {rng.randint(0, 99)};"
    if r < 0.62:
        return f"{ind}{rng.choice(CALLS)}({a}, {b}, {rng.randint(0, 4096)});"
    if r < 0.74:
        return f"{ind}if ({a}->{b} {rng.choice(('<', '>', '==', '!='))} {c}) {{"
    if r < 0.80:
        return f"{ind}for (i = 0; i < {b}; ++i) {{"
    if r < 0.88:
        return f"{ind}// {a} {' '.join(rng.choice(IDENTS) for _ in range(rng.randint(1, 3)))}"
    return f"{ind}{a}->{b} = {c}[{rng.randint(0, 255)}];"


def code_file(rng, n):
    lines, depth = [], 0
    for _ in range(n):
        line = code_line(rng, depth)
        if line.endswith("{"):
            depth = min(depth + 1, 4)
        elif line.strip() == "}":
            depth = max(depth - 1, 0)
        lines.append(line)
    return lines


def edit_hunks(rng, a, n_hunks, max_del, max_ins):
    """Apply n_hunks localized edits (delete up to max_del lines, insert up to
    max_ins freshly written lines) at random positions, like a series of
    commits touching a file."""
    b = list(a)
    for _ in range(n_hunks):
        pos = rng.randrange(len(b) + 1)
        nd = rng.randint(0, max_del)
        ni = rng.randint(0 if nd else 1, max_ins)
        depth = rng.randint(0, 3)
        b[pos:pos + nd] = [code_line(rng, depth) for _ in range(ni)]
    return b


def scatter_edits(rng, a, p_del, p_rep, p_ins):
    b = []
    for line in a:
        r = rng.random()
        if r < p_del:
            continue
        if r < p_del + p_rep:
            b.append(code_line(rng, rng.randint(0, 3)))
        else:
            b.append(line)
        if rng.random() < p_ins:
            b.append(code_line(rng, rng.randint(0, 3)))
    return b


def move_blocks(rng, a, n_moves, min_len, max_len):
    """Cut n_moves blocks of lines and paste them elsewhere (functions
    reordered during a refactor)."""
    b = list(a)
    for _ in range(n_moves):
        length = rng.randint(min_len, max_len)
        start = rng.randrange(len(b) - length)
        block = b[start:start + length]
        del b[start:start + length]
        dest = rng.randrange(len(b) + 1)
        b[dest:dest] = block
    return b


# Long tier: file lengths per case (the short tier uses MAX_LINES for all).
# Hunk and move counts scale with the file length so edit density matches.
# Each gives D of about 18,000, where the reference peaks near 4 GB.
LONG_LINES = (27_000, 13_000, 16_000)
LONG_MAX_INPUT_BYTES = 10_000_000


def build_cases(sizes=(MAX_LINES, MAX_LINES, MAX_LINES)):
    cases = []

    def scaled(count, n):
        return count * n // MAX_LINES

    # 1. Two revisions of a large source file: many localized hunks.
    n = sizes[0]
    rng = random.Random(1001)
    a = code_file(rng, n)
    b = edit_hunks(rng, a, scaled(700, n), 6, 6)[:n]
    cases.append(("001_diff_5000_code_revision", diff_input(a, b), a, b))

    # 2. Heavy rewrite: a third of the lines touched, scattered everywhere.
    n = sizes[1]
    rng = random.Random(2002)
    a = code_file(rng, n)
    b = scatter_edits(rng, a, 0.3, 0.5, 0.3)[:n]
    cases.append(("002_diff_5000_heavy_rewrite", diff_input(a, b), a, b))

    # 3. Refactor: functions moved around plus local edits.
    n = sizes[2]
    rng = random.Random(3003)
    a = code_file(rng, n)
    b = move_blocks(rng, a, scaled(80, n), 20, 80)
    b = edit_hunks(rng, b, scaled(350, n), 4, 5)[:n]
    cases.append(("003_diff_5000_refactor_moves", diff_input(a, b), a, b))
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--long", action="store_true",
                    help="write the long tier to ../bench-long instead of bench/")
    args = ap.parse_args()
    if args.long:
        out_dir, sizes, max_bytes = os.path.join(PROBLEM, "bench-long"), LONG_LINES, LONG_MAX_INPUT_BYTES
        os.makedirs(out_dir, exist_ok=True)
    else:
        out_dir, sizes, max_bytes = HERE, (MAX_LINES,) * 3, MAX_INPUT_BYTES
    for old in os.listdir(out_dir):
        if old.endswith((".in", ".out")):
            os.remove(os.path.join(out_dir, old))
    for name, text, a, b in build_cases(sizes):
        size = len(text.encode("utf-8"))
        assert size < max_bytes, f"{name}: {size} bytes exceeds the input limit"
        assert len(a) <= max(sizes) and len(b) <= max(sizes)
        in_path = os.path.join(out_dir, name + ".in")
        with open(in_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text.encode("utf-8"),
                              capture_output=True, check=True)
        out = proc.stdout.decode("utf-8")
        with open(os.path.join(out_dir, name + ".out"), "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
        script = parse_output(out, name)
        edits = sum(1 for line in script if line[0] != " ")
        minimum = len(a) + len(b) - 2 * lcs_length(a, b)
        assert edits == minimum, f"{name}: expected output has {edits} edits, LCS says {minimum}"
        if args.long:
            assert apply_script(a, script, name) == b, f"{name}: expected script does not produce B"
        print(f"{name}: {size} bytes in, N={len(a)} M={len(b)} D={edits}")

if __name__ == "__main__":
    main()
