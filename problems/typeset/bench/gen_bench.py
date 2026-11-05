#!/usr/bin/env python3
"""Builds the `typeset` performance benchmark inputs deterministically.

Writes three directory-mode cases into this directory, in the same layout as
`tests/` (`NNN_name/input/` and `NNN_name/expected/`), so that

    python3 run_tests.py typeset --tests-dir problems/typeset/bench -- <run.sh>

runs them. Expected outputs come from `reference/main.py`.

    python3 gen_bench.py [--only SUBSTRING] [--no-expected]
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REFERENCE = os.path.join(PROBLEM, "reference", "main.py")
sys.path.insert(0, PROBLEM)

import gen_tests as g  # noqa: E402

LIMIT_FOOTNOTES = 999


def long_book(seed, chapters, footnotes, tables, figures):
    """A long structured book in the style of `gen_tests.book`: TOC, four
    heading levels, nested lists, quotes, listings, tables, figures and
    footnotes spread evenly over `chapters` chapters of four sections."""
    rng = random.Random(seed)
    gen = g.DocGen(seed + 1, 0, footnotes=False)
    slots = chapters * 4
    notes = [footnotes * k // slots for k in range(slots + 1)]
    table_slots = set(rng.sample(range(slots), tables))
    figure_slots = set(rng.sample(range(slots), figures))
    out = ["@doc\ntitle = A Long Generated Book\nauthor = The Bench Author\n"
           "date = 11 October 2026\n@end\n", "@toc\n"]
    slot = 0
    fn_total = 0
    for c in range(chapters):
        out.append("@h1 %s\n" % g.prose(seed * 7 + c, rng.randint(2, 5))[:-1])
        for s in range(4):
            out.append("@h%d %s\n" % (2 + (s % 3 == 2),
                                      g.prose(seed * 11 + c * 4 + s, rng.randint(2, 6))[:-1]))
            if s == 3:
                out.append("@h4 %s\n" % g.prose(seed * 13 + c, 3)[:-1])
            nfn = notes[slot + 1] - notes[slot]
            for p in range(rng.randint(3, 6)):
                text = gen.inline(rng.randint(40, 160), False)
                if nfn and p % 2 == 0:
                    text += "{n|%s}" % gen.inline(rng.randint(5, 50), False)
                    nfn -= 1
                    fn_total += 1
                out.append(g.wrap(text) + "\n")
            while nfn:
                out.append(g.wrap(gen.inline(30, False) + "{n|%s}" % gen.inline(12, False)) + "\n")
                nfn -= 1
                fn_total += 1
            if slot in table_slots:
                cols = rng.randint(2, 6)
                out.append("@table cols=%d align=%s\n"
                           % (cols, "".join(rng.choice("lrc") for _ in range(cols))))
                out.append(" | ".join(gen.word() for _ in range(cols)) + "\n@hrule\n")
                for _ in range(rng.randint(3, 10)):
                    out.append(" | ".join(gen.inline(rng.randint(1, 5), False, styles=False)
                                          for _ in range(cols)) + "\n")
                out.append("@end\n")
            if slot in figure_slots:
                out.append("@fig height=%dpt\n%s\n@end\n"
                           % (rng.randint(60, 200), gen.inline(rng.randint(4, 20), False)))
            if s == 1:
                out.append("@ul\n")
                for _ in range(rng.randint(2, 4)):
                    out.append("@li %s\n" % gen.inline(rng.randint(5, 30), False))
                    if rng.random() < 0.6:
                        out.append("@ol start=%d\n" % rng.randint(1, 30))
                        for _ in range(rng.randint(1, 4)):
                            out.append("@li %s\n" % gen.inline(rng.randint(3, 20), False))
                            if rng.random() < 0.4:
                                out.append("@ul\n@li %s\n@li %s\n@end\n"
                                           % (gen.inline(6, False), gen.inline(9, False)))
                        out.append("@end\n")
                out.append("@end\n")
            if s == 2:
                out.append("@q\n%s\n@end\n" % g.wrap(gen.inline(60, False)))
                out.append("@pre\n%s@end\n" % "".join(
                    "    %s\n" % gen.inline(4, False).replace("\\", "/")
                    for _ in range(rng.randint(3, 8))))
            slot += 1
    assert fn_total == footnotes, fn_total
    return "".join(out)


def case_book(scale=1, footnotes=None):
    doc = long_book(9001, chapters=CHAPTERS * scale,
                    footnotes=FOOTNOTES_BOOK if footnotes is None else footnotes,
                    tables=TABLES * scale, figures=FIGURES * scale)
    return doc, g.BOOK_CFG


def case_paragraphs(n_paras=None):
    """Long unbroken paragraphs (legal or academic prose) on a narrow
    two-column-like measure at the default tolerance: total-fit breaking with
    hyphenation, where about a quarter of the paragraphs need the second pass."""
    n_paras = N_PARAS if n_paras is None else n_paras
    paras = [g.para(9100 + i, PARA_WORDS[i % len(PARA_WORDS)]) for i in range(n_paras)]
    cfg = ("page-width = 6in\npage-height = 9in\n"
           "margin-left = 0.75in\nmargin-right = 2.25in\n"
           "margin-top = 0.8in\nmargin-bottom = 0.8in\n"
           "tolerance = %d\nfooter-center = {page}\nfooter-baseline = 8.6in\n" % PARA_TOLERANCE)
    return "\n".join(paras), cfg


class SparseNoteGen(g.DocGen):
    """`DocGen` with footnotes allowed in only two of every `note_period`
    top-level blocks, so a long document stays within the 999-footnote limit."""

    note_period = 5

    def document(self, doc_meta=None, toc=None):
        out = []
        if doc_meta:
            out.append("@doc\n")
            for k, v in doc_meta:
                out.append("%s = %s\n" % (k, v))
            out.append("@end\n")
        if toc is not None:
            out.append("@toc%s\n" % toc)
        for i in range(self.size):
            self.footnotes = i % self.note_period < 2
            self.block(0, out)
        return "".join(out)


def case_mixed(scale=1, blocks=None, seed=9200):
    """A long random document of every block kind, with footnotes, floating
    figures, tables, nested lists and a TOC, on A5 pages with running heads."""
    while True:
        gen = SparseNoteGen(seed, blocks or MIXED_BLOCKS * scale, fig_max=60)
        gen.note_period = 5 * scale
        doc = gen.document(
            [("title", "Mixed workload"), ("author", "Bench"), ("date", "2026")], "")
        if doc.count("{n|") <= LIMIT_FOOTNOTES:
            break
        seed += 1
    cfg = ("page-width = 148mm\npage-height = 210mm\nmargin-left = 15mm\n"
           "margin-right = 15mm\nmargin-top = 20mm\nmargin-bottom = 20mm\n"
           "header-baseline = 12mm\nfooter-baseline = 200mm\n"
           "header-left-even = {title}\nheader-right = {chapter}\n"
           "header-right-even = {section}\nfooter-center = {page} of {pages}\n"
           "widows = 2\norphans = 2\n")
    return doc, cfg


# Workload sizes, chosen so the faster compiled implementations take roughly
# 0.3-3 seconds per case while the expected outputs stay within the size budget.
CHAPTERS = 60
FOOTNOTES_BOOK = 600
TABLES = 80
FIGURES = 90
N_PARAS = 40
PARA_WORDS = [1500, 2500, 3500, 2000]
PARA_TOLERANCE = 1000
MIXED_BLOCKS = 2400

CASES = [
    ("001_book_throughput", case_book),
    ("002_long_paragraphs_linebreak", case_paragraphs),
    ("003_mixed_floats_footnotes", case_mixed),
]

# Long tier (--long, written to ../bench-long). 002 sets eight times
# as many long paragraphs. 001 and 003 are twice as long: their TOC settings
# reserve room for three-digit page labels, so they must stay under 1000
# pages, and the 999-footnote guarantee makes 001's footnotes sparser.
LONG_CASES = [
    ("001_book_throughput", lambda: case_book(2, LIMIT_FOOTNOTES)),
    ("002_long_paragraphs_linebreak", lambda: case_paragraphs(320)),
    ("003_mixed_floats_footnotes", lambda: case_mixed(2)),
]


def write(path, text):
    with open(path, "wb") as f:
        f.write(text.encode("utf-8"))


def expected_from_impls(name, inp, exp, cmds):
    """Run each implementation command (cwd = the problem directory); their
    output trees must agree file for file, and become the expected tree."""
    outs = []
    for k, cmd in enumerate(cmds):
        out = exp if k == 0 else exp + ".check%d" % k
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out)
        subprocess.run(cmd + " " + inp + " " + out, shell=True, check=True, cwd=PROBLEM)
        outs.append(out)
    for out in outs[1:]:
        for fn in sorted(os.listdir(exp)):
            with open(os.path.join(exp, fn), "rb") as a, open(os.path.join(out, fn), "rb") as b:
                if a.read() != b.read():
                    raise SystemExit("%s: implementations disagree on %s" % (name, fn))
        shutil.rmtree(out)


def build(name, fn, expected, out_root=HERE, impls=()):
    root = os.path.join(out_root, name)
    shutil.rmtree(root, ignore_errors=True)
    inp = os.path.join(root, "input")
    os.makedirs(inp)
    doc, cfg = fn()
    write(os.path.join(inp, "document.cdx"), doc)
    write(os.path.join(inp, "settings.cfg"), cfg)
    if not expected:
        return
    exp = os.path.join(root, "expected")
    t0 = time.time()
    if impls:
        expected_from_impls(name, inp, exp, impls)
        print("%s: expected output agreed by %d implementations" % (name, len(impls)))
        return
    os.makedirs(exp)
    proc = subprocess.run([sys.executable, REFERENCE, inp, exp],
                          capture_output=True, cwd=PROBLEM)
    if proc.returncode != 0:
        raise SystemExit("%s: reference exited %d: %s"
                         % (name, proc.returncode, proc.stderr.decode("utf-8", "replace")[:1500]))
    if os.path.exists(os.path.join(exp, "error.txt")):
        raise SystemExit("%s: reference reported an error: %s"
                         % (name, open(os.path.join(exp, "error.txt")).read()))
    with open(os.path.join(exp, "report.txt")) as f:
        pages = int(next(l for l in f if l.startswith("pages ")).split()[1])
    if pages >= 3000 or ("@toc" in doc and pages >= 1000):
        raise SystemExit("%s: %d pages; too many for the page-label guarantees" % (name, pages))
    print("%s: reference %.1fs, %d pages" % (name, time.time() - t0, pages))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--no-expected", action="store_true",
                    help="write inputs only, without running the reference")
    ap.add_argument("--long", action="store_true",
                    help="write the long tier to ../bench-long")
    ap.add_argument("--expected-from", action="append", default=[], metavar="CMD",
                    help="long tier: take the expected output from these implementation "
                         "commands (which must agree) instead of the reference")
    args = ap.parse_args()
    cases, out_root = CASES, HERE
    if args.long:
        cases, out_root = LONG_CASES, os.path.join(PROBLEM, "bench-long")
    for name, fn in cases:
        if args.only in name:
            impls = args.expected_from if args.long else ()
            build(name, fn, not args.no_expected, out_root, impls)
    return 0


if __name__ == "__main__":
    sys.exit(main())
