#!/usr/bin/env python3
"""Verifier for the `fulltext` problem.

Usage: verify.py <input dir> <actual output dir> <expected output dir>

Ranking, document ids and snippets must match exactly; the printed scores are
sums of logarithms and divisions, so they are compared numerically with an
absolute tolerance of 1e-3 (the expected outputs are generated so that no two
neighbouring scores in a ranking are closer than 1e-9 unless they are equal,
which makes the order itself reproducible).

Exit 0 on pass; otherwise print a reason and exit 1.
"""
import math
import os
import sys

SCORE_TOL = 1e-3
FILES = ("results.txt", "stats.txt")


def fail(message):
    print(message)
    sys.exit(1)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        data = f.read()
    data = data.replace("\r\n", "\n").replace("\r", "\n")
    lines = [line.rstrip(" \t") for line in data.split("\n")]
    while lines and lines[-1] == "":
        lines.pop()
    return lines


def parse_results(lines, who):
    """Return a list of (header, hits line, [(rank, doc, score, snippet)])."""
    blocks = []
    i = 0
    while i < len(lines):
        header = lines[i]
        if not header.startswith("QUERY "):
            fail("%s: line %d should start a query block: %r" % (who, i + 1, header))
        i += 1
        if i >= len(lines) or not lines[i].startswith("HITS "):
            fail("%s: missing HITS line after %r" % (who, header))
        try:
            count = int(lines[i][5:])
        except ValueError:
            fail("%s: bad HITS line %r" % (who, lines[i]))
        i += 1
        rows = []
        for _ in range(count):
            if i >= len(lines):
                fail("%s: %r promises %d hits but the file ends" % (who, header, count))
            parts = lines[i].split("\t")
            if len(parts) == 3:
                parts.append("")
            if len(parts) != 4:
                fail("%s: result line %d has %d tab-separated fields, expected 4: %r"
                     % (who, i + 1, len(parts), lines[i]))
            try:
                rank = int(parts[0])
                score = float(parts[2])
            except ValueError:
                fail("%s: bad result line %r" % (who, lines[i]))
            if not math.isfinite(score):
                fail("%s: score %r is not a finite number: %r"
                     % (who, parts[2], lines[i]))
            rows.append((rank, parts[1], score, parts[3]))
            i += 1
        blocks.append((header, count, rows))
    return blocks


def compare_results(actual, expected):
    a = parse_results(actual, "actual")
    e = parse_results(expected, "expected")
    if len(a) != len(e):
        fail("results.txt has %d query blocks, expected %d" % (len(a), len(e)))
    for (ah, ac, ar), (eh, ec, er) in zip(a, e):
        if ah != eh:
            fail("query header %r, expected %r" % (ah, eh))
        if ac != ec:
            fail("%s: HITS %d, expected %d" % (eh, ac, ec))
        for (arank, adoc, ascore, asnip), (erank, edoc, escore, esnip) in zip(ar, er):
            if arank != erank:
                fail("%s: rank %d, expected %d" % (eh, arank, erank))
            if adoc != edoc:
                fail("%s: rank %d is %r, expected %r" % (eh, erank, adoc, edoc))
            if abs(ascore - escore) > SCORE_TOL:
                fail("%s: rank %d (%s) scored %.6f, expected %.6f"
                     % (eh, erank, edoc, ascore, escore))
            if asnip != esnip:
                fail("%s: rank %d (%s) snippet\n  actual:   %r\n  expected: %r"
                     % (eh, erank, edoc, asnip, esnip))


def compare_stats(actual, expected):
    a = dict(line.split(" ", 1) for line in actual if " " in line)
    e = dict(line.split(" ", 1) for line in expected if " " in line)
    for key in ("documents", "tokens", "terms", "avgdl"):
        if key not in a:
            fail("stats.txt is missing the %r line" % key)
    if set(a) != set(e):
        fail("stats.txt keys %s, expected %s" % (sorted(a), sorted(e)))
    for key in ("documents", "tokens", "terms"):
        if a[key].strip() != e[key].strip():
            fail("stats.txt %s is %s, expected %s" % (key, a[key].strip(), e[key].strip()))
    try:
        got, want = float(a["avgdl"]), float(e["avgdl"])
    except ValueError:
        fail("stats.txt avgdl is not a number: %r" % a["avgdl"])
    if not math.isfinite(got):
        fail("stats.txt avgdl is not a finite number: %r" % a["avgdl"])
    if abs(got - want) > SCORE_TOL:
        fail("stats.txt avgdl is %.6f, expected %.6f" % (got, want))


def main(argv):
    if len(argv) < 4:
        fail("usage: verify.py <input> <actual dir> <expected dir>")
    actual_dir, expected_dir = argv[2], argv[3]
    produced = sorted(
        os.path.relpath(os.path.join(dp, fn), actual_dir)
        for dp, _dn, fns in os.walk(actual_dir) for fn in fns)
    missing = [f for f in FILES if f not in produced]
    if missing:
        fail("missing output files: %s" % ", ".join(missing))
    extra = [f for f in produced if f not in FILES]
    if extra:
        fail("unexpected output files: %s" % ", ".join(extra[:5]))
    compare_results(read(os.path.join(actual_dir, "results.txt")),
                    read(os.path.join(expected_dir, "results.txt")))
    compare_stats(read(os.path.join(actual_dir, "stats.txt")),
                  read(os.path.join(expected_dir, "stats.txt")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
