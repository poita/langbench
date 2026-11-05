#!/usr/bin/env python3
"""Builds the whole `typeset` test suite, public and hidden.

Every case is a directory-mode test: `tests/NNN_name/input/` holds
`document.cdx` and (usually) `settings.cfg`, and `tests/NNN_name/expected/`
holds the tree that `reference/main.py` produces from it. Cases are written to

  * problems/typeset/tests/                        (public, about a quarter)
  * $LANGBENCH_HIDDEN (default: langbench-hidden next to this checkout)/typeset/tests/   (hidden, the rest)

sharing one `NNN` sequence so names never collide, and stratified by the `area`
of each case so that every feature area appears in both sets.

Hand-written cases come first, grouped by area. Each may carry independent
assertions taken from SPEC.md rather than from the reference:

  * `error`  — the exact single line of `error.txt`,
  * `layout` — the exact text of `layout.txt` (used for the worked examples),
  * `report` — required `report.txt` values,
  * `want`   — item lines that must appear in `layout.txt` in this order,
  * `unwant` — substrings that must not appear in `layout.txt`.

A disagreement between such an assertion and the reference aborts generation
rather than silently blessing a wrong answer. Generated cases follow:
deterministic pseudo-random documents of growing size from fixed seeds.

    python3 gen_tests.py [--only SUBSTRING] [--jobs N] [--list]
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE = os.path.join(HERE, "reference", "main.py")
PUBLIC_DIR = os.path.join(HERE, "tests")
HIDDEN_DIR = os.path.join(os.environ.get("LANGBENCH_HIDDEN") or os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "langbench-hidden")), "typeset", "tests")

CASES = []


def case(name, doc, cfg=None, pub=None, error=None, layout=None, report=None,
         want=(), wantsub=(), unwant=(), free=False, extra=None):
    """Register one test case.

    `doc` is the text of `document.cdx` (None omits the file entirely, which
    is the `missing-document` case) and `cfg` the text of `settings.cfg`
    (None omits it, so every setting takes its default). `pub` forces the
    case into the public (True) or hidden (False) set; None lets
    `split_cases` choose. `error` is either the whole `error.txt` line or,
    when it contains no `:`, just the expected error code. `free` cases
    (the error-injection family) may end either way and are not checked.
    `extra` maps further input file names to their text; the engine must
    ignore them.
    """
    area = name.split("_", 1)[0]
    CASES.append({
        "name": name,
        "area": area,
        "doc": doc,
        "cfg": cfg,
        "pub": pub,
        "error": error,
        "layout": layout,
        "report": dict(report or {}),
        "want": list(want),
        "wantsub": list(wantsub),
        "unwant": list(unwant),
        "free": free,
        "extra": dict(extra or {}),
    })


def pcase(name, *args, **kwargs):
    """Register a case that is always public."""
    kwargs["pub"] = True
    case(name, *args, **kwargs)


def hcase(name, *args, **kwargs):
    """Register a case that is always hidden."""
    kwargs["pub"] = False
    case(name, *args, **kwargs)


# ---------------------------------------------------------------------------
# materialising and running
# ---------------------------------------------------------------------------

def materialize(spec, root):
    inp = os.path.join(root, "input")
    os.makedirs(inp)
    if spec["doc"] is not None:
        with open(os.path.join(inp, "document.cdx"), "wb") as f:
            f.write(spec["doc"].encode("utf-8"))
    if spec["cfg"] is not None:
        with open(os.path.join(inp, "settings.cfg"), "wb") as f:
            f.write(spec["cfg"].encode("utf-8"))
    for name, text in sorted(spec["extra"].items()):
        with open(os.path.join(inp, name), "wb") as f:
            f.write(text.encode("utf-8"))


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8")


def check(spec, expected):
    """Confirm the reference output satisfies the case's own assertions."""
    files = sorted(os.listdir(expected))
    if spec["free"]:
        return None
    if spec["error"] is not None:
        if files != ["error.txt"]:
            return "expected only error.txt, got %s" % files
        got = read(os.path.join(expected, "error.txt"))
        if ":" not in spec["error"]:
            if not got.endswith(": " + spec["error"] + "\n"):
                return "error.txt is %r, expected code %s" % (got, spec["error"])
            return None
        if got != spec["error"] + "\n":
            return "error.txt is %r, expected %r" % (got, spec["error"] + "\n")
        return None
    if files != ["layout.txt", "report.txt"]:
        return "expected layout.txt and report.txt, got %s" % files
    layout = read(os.path.join(expected, "layout.txt"))
    report = read(os.path.join(expected, "report.txt"))
    if spec["layout"] is not None:
        if layout != spec["layout"]:
            return "layout.txt mismatch\n--- expected ---\n%s--- actual ---\n%s" % (
                spec["layout"], layout)
    values = {}
    for line in report.strip("\n").split("\n")[1:]:
        key, value = line.split(" ")
        values[key] = int(value)
    for key, value in spec["report"].items():
        if key not in values:
            return "report.txt has no key %s" % key
        if values[key] != value:
            return "report %s is %d, expected %d" % (key, values[key], value)
    lines = layout.split("\n")
    i = 0
    for wanted in spec["want"]:
        while i < len(lines) and lines[i] != wanted:
            i += 1
        if i == len(lines):
            return "expected layout line not found: %r" % wanted
        i += 1
    for wanted in spec["wantsub"]:
        if wanted not in layout:
            return "expected layout substring not found: %r" % wanted
    for bad in spec["unwant"]:
        if bad in layout:
            return "forbidden text in layout.txt: %r" % bad
    return None


def build_case(index, spec, out_root):
    name = "%03d_%s" % (index, spec["name"])
    root = os.path.join(out_root, name)
    shutil.rmtree(root, ignore_errors=True)
    materialize(spec, root)
    expected = os.path.join(root, "expected")
    os.makedirs(expected)
    proc = subprocess.run([sys.executable, REFERENCE,
                           os.path.join(root, "input"), expected],
                          capture_output=True, cwd=HERE)
    if proc.returncode != 0:
        raise SystemExit("%s: reference exited %d: %s"
                         % (name, proc.returncode,
                            proc.stderr.decode("utf-8", "replace")[:1500]))
    problem = check(spec, expected)
    if problem:
        raise SystemExit("%s: %s" % (name, problem))
    size = sum(os.path.getsize(os.path.join(dp, fn))
               for dp, _, fns in os.walk(root) for fn in fns)
    return name, size


def split_cases():
    """Assign each case to the public or the hidden set.

    Cases registered with an explicit `pub` keep it. Within each area the
    remaining cases are dealt out in registration order so that the first of
    every four is public, which keeps about a quarter of every area public.
    The split is then checked: every area must appear in both sets.
    """
    by_area = {}
    for spec in CASES:
        by_area.setdefault(spec["area"], []).append(spec)
    for specs in by_area.values():
        dealt = 0
        for spec in specs:
            if spec["pub"] is None:
                spec["pub"] = dealt % 4 == 0
                dealt += 1
    problems = []
    for area, specs in sorted(by_area.items()):
        public = [s for s in specs if s["pub"]]
        if not public:
            problems.append("area %s has no public case" % area)
        if len(public) == len(specs):
            problems.append("area %s has no hidden case" % area)
    if problems:
        raise SystemExit("\n".join(problems))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="only build cases whose name contains this")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--list", action="store_true", help="list the cases and stop")
    args = ap.parse_args()

    register_all()
    names = [c["name"] for c in CASES]
    if len(set(names)) != len(names):
        dupes = sorted({n for n in names if names.count(n) > 1})
        raise SystemExit("duplicate case names: %s" % ", ".join(dupes))
    split_cases()

    if args.list:
        for i, spec in enumerate(CASES, 1):
            print("%03d_%-44s %s" % (i, spec["name"], "public" if spec["pub"] else "hidden"))
        print("%d cases, %d public, %d hidden"
              % (len(CASES), sum(1 for c in CASES if c["pub"]),
                 sum(1 for c in CASES if not c["pub"])))
        return 0

    if not args.only:
        shutil.rmtree(PUBLIC_DIR, ignore_errors=True)
        shutil.rmtree(HIDDEN_DIR, ignore_errors=True)
    os.makedirs(PUBLIC_DIR, exist_ok=True)
    os.makedirs(HIDDEN_DIR, exist_ok=True)

    work = []
    for i, spec in enumerate(CASES, 1):
        if args.only and args.only not in spec["name"]:
            continue
        work.append((i, spec, PUBLIC_DIR if spec["pub"] else HIDDEN_DIR))

    totals = {PUBLIC_DIR: 0, HIDDEN_DIR: 0}
    counts = {PUBLIC_DIR: 0, HIDDEN_DIR: 0}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for (i, spec, dest), result in zip(
                work, pool.map(lambda t: build_case(*t), work)):
            name, size = result
            totals[dest] += size
            counts[dest] += 1
            if size > 400 * 1024:
                print("%-48s %-6s %8.1f KiB"
                      % (name, "public" if dest is PUBLIC_DIR else "hidden", size / 1024.0))

    print()
    print("public: %d cases, %.1f MiB" % (counts[PUBLIC_DIR], totals[PUBLIC_DIR] / 1048576.0))
    print("hidden: %d cases, %.1f MiB" % (counts[HIDDEN_DIR], totals[HIDDEN_DIR] / 1048576.0))
    for dest, total in totals.items():
        if total > 38 * 1048576:
            raise SystemExit("%s exceeds the 40MB budget" % dest)
    return 0


# ---------------------------------------------------------------------------
# shared fragments
# ---------------------------------------------------------------------------

# The settings file the spec's worked examples 5 to 18 use.
SMALL = """# small.cfg
page-width   = 200pt
page-height  = 120pt
margin-top   = 20pt
margin-bottom = 20pt
margin-left  = 20pt
margin-right = 20pt
"""

def merge(base, extra):
    """`base` settings text with the assignments of `extra` appended, after
    dropping any line of `base` that assigns a key `extra` assigns too."""
    keys = {l.split("=", 1)[0].strip() for l in extra.split("\n") if "=" in l}
    kept = [l for l in base.split("\n")
            if l and not ("=" in l and l.split("=", 1)[0].strip() in keys)]
    return "\n".join(kept) + "\n" + extra + ("" if extra.endswith("\n") or not extra else "\n")


# The same small page with a taller body, for multi-page documents.
TALL = merge(SMALL, "page-height = 240pt")

PAGE1 = "page 1 1 200000 120000 20000 20000 160000 80000"


def L(*lines):
    """Join item lines into a complete layout.txt with a trailing newline."""
    return "\n".join(lines) + "\n"


def small(extra):
    """The small page plus extra settings lines."""
    return merge(SMALL, extra)


FOX = "The quick brown fox jumps over the lazy dog.\n"

# A paragraph that reliably fills several lines of the small page.
LOREM = (
    "Codexa measures every fragment in glyph space and scales the total once, "
    "so that two correct implementations agree to the millipoint on every "
    "single line of the finished page.\n")


# ---------------------------------------------------------------------------
# the spec's worked examples
# ---------------------------------------------------------------------------

def g_examples():
    pcase("ex_05_one_line", "The quick brown fox.\n", SMALL,
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body serif 10000 38000 27310 15630 "The"',
                   '  text body serif 10000 56170 27310 22240 "quick"',
                   '  text body serif 10000 80950 27310 25140 "brown"',
                   '  text body serif 10000 108630 27310 15810 "fox."'),
          report={"pages": 1, "front-pages": 0, "body-pages": 1, "lines": 1,
                  "paragraphs": 1, "headings": 0, "tables": 0, "figures": 0,
                  "footnotes": 0, "footnote-split-lines": 0,
                  "hyphenated-lines": 0, "overfull-lines": 0,
                  "emergency-lists": 0, "total-demerits": 100})

    pcase("ex_06_two_justified_lines", FOX, SMALL,
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body serif 10000 38000 27310 15630 "The"',
                   '  text body serif 10000 55521 27310 22240 "quick"',
                   '  text body serif 10000 79653 27310 25140 "brown"',
                   '  text body serif 10000 106685 27310 13280 "fox"',
                   '  text body serif 10000 121856 27310 24600 "jumps"',
                   '  text body serif 10000 148348 27310 17390 "over"',
                   '  text body serif 10000 167630 27310 12370 "the"',
                   '  text body serif 10000 20000 39310 16370 "lazy"',
                   '  text body serif 10000 38910 39310 17480 "dog."'),
          report={"lines": 2, "total-demerits": 3016})

    pcase("ex_07a_align_left", FOX, small("align = left"),
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body serif 10000 38000 27310 15630 "The"',
                   '  text body serif 10000 56170 27310 22240 "quick"',
                   '  text body serif 10000 80950 27310 25140 "brown"',
                   '  text body serif 10000 108630 27310 13280 "fox"',
                   '  text body serif 10000 124450 27310 24600 "jumps"',
                   '  text body serif 10000 151590 27310 17390 "over"',
                   '  text body serif 10000 20000 39310 12370 "the"',
                   '  text body serif 10000 34910 39310 16370 "lazy"',
                   '  text body serif 10000 53820 39310 17480 "dog."'),
          report={"lines": 2, "total-demerits": 244})

    hcase("ex_07b_align_right", FOX, small("align = right"),
         layout=L("layout 1", "pages 1", PAGE1,
                  '  text body serif 10000 49020 27310 15630 "The"',
                  '  text body serif 10000 67190 27310 22240 "quick"',
                  '  text body serif 10000 91970 27310 25140 "brown"',
                  '  text body serif 10000 119650 27310 13280 "fox"',
                  '  text body serif 10000 135470 27310 24600 "jumps"',
                  '  text body serif 10000 162610 27310 17390 "over"',
                  '  text body serif 10000 128700 39310 12370 "the"',
                  '  text body serif 10000 143610 39310 16370 "lazy"',
                  '  text body serif 10000 162520 39310 17480 "dog."'),
         report={"lines": 2, "total-demerits": 244})

    hcase("ex_07c_align_center", FOX, small("align = center"),
         layout=L("layout 1", "pages 1", PAGE1,
                  '  text body serif 10000 43510 27310 15630 "The"',
                  '  text body serif 10000 61680 27310 22240 "quick"',
                  '  text body serif 10000 86460 27310 25140 "brown"',
                  '  text body serif 10000 114140 27310 13280 "fox"',
                  '  text body serif 10000 129960 27310 24600 "jumps"',
                  '  text body serif 10000 157100 27310 17390 "over"',
                  '  text body serif 10000 74350 39310 12370 "the"',
                  '  text body serif 10000 89260 39310 16370 "lazy"',
                  '  text body serif 10000 108170 39310 17480 "dog."'),
         report={"lines": 2, "total-demerits": 244})

    pcase("ex_08_hyphenated_break",
          "Algorithm integer column every typesetting.\n",
          small("par-indent = 0"),
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body serif 10000 20000 27310 41620 "Algorithm"',
                   '  text body serif 10000 63382 27310 27800 "integer"',
                   '  text body serif 10000 92945 27310 29880 "column"',
                   '  text body serif 10000 124587 27310 22030 "every"',
                   '  text body serif 10000 148380 27310 31620 "typeset-"',
                   '  text body serif 10000 20000 39310 18120 "ting."'),
          report={"lines": 2, "paragraphs": 1, "hyphenated-lines": 1,
                  "overfull-lines": 0, "emergency-lists": 0,
                  "total-demerits": 14996})

    pcase("ex_09_numbered_heading",
          "@h1 Introduction\nThe quick brown fox.\n", SMALL,
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body sans-bold 20000 20000 35460 11400 "1"',
                   '  text body sans-bold 20000 37400 35460 114340 "Introduction"',
                   '  text body serif 10000 38000 56630 15630 "The"',
                   '  text body serif 10000 56170 56630 22240 "quick"',
                   '  text body serif 10000 80950 56630 25140 "brown"',
                   '  text body serif 10000 108630 56630 15810 "fox."'),
          report={"lines": 2, "paragraphs": 1, "headings": 1,
                  "total-demerits": 200})

    pcase("ex_10_nested_lists",
          "@ul\n@li First item.\n@li Second item.\n@ul\n@li Nested one.\n@end\n@end\n",
          SMALL,
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body serif 10000 30560 27310 3440 "•"',
                   '  text body serif 10000 38000 27310 18360 "First"',
                   '  text body serif 10000 58900 27310 20350 "item."',
                   '  text body serif 10000 30560 39310 3440 "•"',
                   '  text body serif 10000 38000 39310 29430 "Second"',
                   '  text body serif 10000 69970 39310 20350 "item."',
                   '  text body serif 10000 47060 54850 4940 "–"',
                   '  text body serif 10000 56000 54850 28070 "Nested"',
                   '  text body serif 10000 86610 54850 16950 "one."'),
          report={"lines": 3, "paragraphs": 0, "total-demerits": 300})

    pcase("ex_11_preformatted",
          "@pre\nlet x = 1\n  y = x + 2\n@end\n", SMALL,
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body mono 9000 20000 26300 48600 "let x = 1"',
                   '  text body mono 9000 20000 37300 59400 "  y = x + 2"'),
          report={"lines": 2, "paragraphs": 0, "total-demerits": 0})

    pcase("ex_12a_table_fits",
          "@table cols=3 align=llr\nItem | Qty | Price\n@hrule\n"
          "Widget | 2 | 4.50\nGadget | 11 | 19.95\n@end\n", SMALL,
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body serif 10000 20000 27310 18470 "Item"',
                   '  text body serif 10000 57530 27310 15000 "Qty"',
                   '  text body serif 10000 82550 27310 20440 "Price"',
                   "  rule body 20000 31540 82990 400",
                   '  text body serif 10000 20000 41250 29530 "Widget"',
                   '  text body serif 10000 57530 41250 4990 "2"',
                   '  text body serif 10000 85510 41250 17480 "4.50"',
                   '  text body serif 10000 20000 52790 29060 "Gadget"',
                   '  text body serif 10000 57530 52790 9840 "11"',
                   '  text body serif 10000 80530 52790 22460 "19.95"'),
          report={"lines": 9, "tables": 1})

    hcase("ex_12b_table_shrinks",
         "@table cols=2 align=ll\nColumn heading one | Column heading two\n"
         "A rather long cell value here | Short\n@end\n", SMALL,
         wantsub=['  text body serif 10000 20000 27310 32190 "Column"',
                  '  text body serif 10000 113871 27310 32190 "Column"'],
         report={"tables": 1})

    pcase("ex_13_footnote", "Delta{n|A short note.} gamma.\n", SMALL,
          layout=L("layout 1", "pages 1", PAGE1,
                   '  text body serif 7000 59720 25117 3444 "1"',
                   '  text body serif 10000 38000 28117 21720 "Delta"',
                   '  text body serif 10000 65704 28117 32050 "gamma."',
                   "  rule footnote 20000 88968 120000 400",
                   '  text footnote serif 6000 25048 96216 2952 "1"',
                   '  text footnote serif 8000 30000 98216 5864 "A"',
                   '  text footnote serif 8000 37896 98216 15984 "short"',
                   '  text footnote serif 8000 55912 98216 15800 "note."'),
          report={"lines": 2, "footnotes": 1, "footnote-split-lines": 0,
                  "total-demerits": 200})

    pcase("ex_15_deferred_figure",
          "@fig height=30pt\nA framed box.\n@end\nAlpha one.\n\nBeta two.\n",
          SMALL,
          layout=L("layout 1", "pages 2", PAGE1,
                   '  text body serif 10000 38000 27310 24510 "Alpha"',
                   '  text body serif 10000 65050 27310 16950 "one."',
                   '  text body serif 10000 38000 39310 18290 "Beta"',
                   '  text body serif 10000 58830 39310 17420 "two."',
                   "page 2 2 200000 120000 20000 20000 160000 80000",
                   "  box float 20000 20000 160000 30000",
                   '  text float serif 9000 55556 60579 23571 "Figure"',
                   '  text float serif 9000 81413 60579 6705 "1."',
                   '  text float serif 9000 92118 60579 6597 "A"',
                   '  text float serif 9000 101001 60579 25515 "framed"',
                   '  text float serif 9000 128802 60579 15642 "box."'),
          report={"pages": 2, "lines": 3, "paragraphs": 2, "figures": 1,
                  "total-demerits": 300})

    pcase("ex_16_table_of_contents",
          "@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n",
          SMALL,
          layout=L("layout 1", "pages 3",
                   "page 1 i 200000 120000 20000 20000 160000 80000",
                   '  text body sans-bold 20000 20000 35460 82500 "Contents"',
                   '  text body serif 10000 20000 59630 4920 "1"',
                   '  text body serif 10000 30920 59630 49280 "Introduction"',
                   '  text body serif 10000 83530 59630 88550 "%s"' % ("." * 35),
                   '  text body serif 10000 175080 59630 4920 "1"',
                   '  text body serif 10000 20000 73630 4990 "2"',
                   '  text body serif 10000 30990 73630 29740 "Results"',
                   '  text body serif 10000 65750 73630 106260 "%s"' % ("." * 42),
                   '  text body serif 10000 175010 73630 4990 "2"',
                   "page 2 1 200000 120000 20000 20000 160000 80000",
                   '  text body sans-bold 20000 20000 35460 11400 "1"',
                   '  text body sans-bold 20000 37400 35460 114340 "Introduction"',
                   '  text body serif 10000 38000 56630 24510 "Alpha"',
                   '  text body serif 10000 65050 56630 16950 "one."',
                   "page 3 2 200000 120000 20000 20000 160000 80000",
                   '  text body sans-bold 20000 20000 35460 11320 "2"',
                   '  text body sans-bold 20000 37320 35460 68900 "Results"',
                   '  text body serif 10000 38000 56630 18290 "Beta"',
                   '  text body serif 10000 58830 56630 17420 "two."'),
          report={"pages": 3, "front-pages": 1, "body-pages": 2, "lines": 7,
                  "paragraphs": 2, "headings": 2, "total-demerits": 700})

    pcase("ex_17a_bad_length_in_settings", "Alpha beta.\n",
          "page-width = 200pt\nmargin-left = 20px\n",
          error="settings.cfg:2:15: bad-length")

    pcase("ex_17b_unknown_inline", "@h1 Title\n{z|oops}\n", SMALL,
          error="document.cdx:2:1: unknown-inline")

    pcase("ex_18_running_headers",
          "@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n",
          small("header-baseline = 10pt\nfooter-baseline = 112pt\n"
                "header-right = {chapter}\nfooter-center = {page}"),
          want=['  text footer sans 9000 98780 112000 2439 "i"',
                '  text header sans 9000 127413 10000 4545 "1"',
                '  text header sans 9000 134487 10000 45513 "Introduction"',
                '  text footer sans 9000 97727 112000 4545 "1"'],
          report={"pages": 3, "front-pages": 1})

    hcase("ex_18b_even_header_fallback",
         "@toc\n@h1 Introduction\nAlpha one.\n@newpage\n@h1 Results\nBeta two.\n",
         small("header-baseline = 10pt\nfooter-baseline = 112pt\n"
               "header-right = {chapter}\nfooter-center = {page}"),
         wantsub=['  text header sans 9000 145530 10000 4509 "2"',
                  '  text header sans 9000 152568 10000 27432 "Results"',
                  '  text footer sans 9000 97745 112000 4509 "2"'])


# ---------------------------------------------------------------------------
# helpers for hand-written cases
# ---------------------------------------------------------------------------

DOC1 = "Alpha beta gamma.\n"


def at(text, line, sub, nth=0):
    """The 1-based column of the `nth` occurrence of `sub` in line `line`
    (1-based) of `text`, counted in Unicode scalar values."""
    src = text.split("\n")[line - 1]
    pos = -1
    for _ in range(nth + 1):
        pos = src.index(sub, pos + 1)
    return pos + 1


def derr(text, line, sub, code, nth=0):
    """The error line for document.cdx at the given occurrence."""
    return "document.cdx:%d:%d: %s" % (line, at(text, line, sub, nth), code)


def serr(text, line, sub, code, nth=0):
    """The error line for settings.cfg at the given occurrence."""
    return "settings.cfg:%d:%d: %s" % (line, at(text, line, sub, nth), code)


# A medium page: 300pt x 400pt with 30pt margins, body 240pt x 340pt.
MED = """page-width = 300pt
page-height = 400pt
margin-top = 30pt
margin-bottom = 30pt
margin-left = 30pt
margin-right = 30pt
"""


def med(extra=""):
    return merge(MED, extra)


WORDS = (
    "the of and a to in is was that for on are with as his they be at one "
    "have this from by hot word but what some we can out other were all "
    "there when up use your how said an each she which do their time if "
    "will way about many then them write would like so these her long make "
    "thing see him two has look more day could go come did number sound no "
    "most people my over know water than call first who may down side been "
    "now find any new work part take get place made live where after back "
    "little only round man year came show every good me give our under name "
    "very through just form sentence great think say help low line differ "
    "turn cause much mean before move right boy old too same tell does set "
    "three want air well also play small end put home read hand port large "
    "spell add even land here must big high such follow act why ask men "
    "change went light kind off need house picture try us again animal point "
    "mother world near build self earth father typesetting national "
    "introduction algorithm paragraph hyphenation winter interesting "
    "conversation information government important development international "
    "experience university community particular understanding relationship "
    "temperature organization environmental responsibility characteristic "
    "measurement mathematics probability engineering discretionary "
    "codexa typeset integer column heading rather strength straight thought "
    "bright through exceptional performance consideration establishment "
    "approximately significantly unfortunately independently "
    "telecommunication representative accommodation"
).split()

UNICODE_WORDS = ["café", "naïve", "façade", "Ångström", "über", "jalapeño",
                 "“quoted”", "‘single’", "—", "…", "½", "∑", "漢字", "Ωmega",
                 "coöperate", "résumé", "déjà", "Zoë"]


def sentence(rng, n, cap=True):
    words = [rng.choice(WORDS) for _ in range(n)]
    if cap:
        words[0] = words[0][0].upper() + words[0][1:]
    return " ".join(words) + rng.choice([".", ".", ".", "!", "?", ";", ","])


def prose(seed, nwords, per_sentence=(5, 14)):
    rng = random.Random(seed)
    out = []
    count = 0
    while count < nwords:
        n = min(rng.randint(*per_sentence), max(1, nwords - count))
        out.append(sentence(rng, n))
        count += n
    return " ".join(out)


def wrap(text, width=70):
    """Wrap source text into continuation lines (no effect on output)."""
    lines, cur = [], ""
    for w in text.split(" "):
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = w if not cur else cur + " " + w
    if cur:
        lines.append(cur)
    return "\n".join(lines) + "\n"


def para(seed, nwords):
    return wrap(prose(seed, nwords))


# ---------------------------------------------------------------------------
# settings-file errors and values
# ---------------------------------------------------------------------------

def g_settings():
    def se(name, cfg, line, sub, code, nth=0, doc=DOC1, **kw):
        case(name, doc, cfg, error=serr(cfg, line, sub, code, nth), **kw)

    se("set_bad_syntax_no_equals", "page-width 200pt\n", 1, "p", "bad-syntax")
    se("set_bad_syntax_uppercase_key", "# comment\n\n   Page-width = 1pt\n", 3, "P", "bad-syntax")
    se("set_bad_syntax_empty_key", "page-width = 200pt\n  = 5pt\n", 2, "=", "bad-syntax")
    se("set_unknown_setting", "  page-wdth = 200pt\n", 1, "p", "unknown-setting")
    se("set_unknown_setting_before_value", "tolerence = abc\n", 1, "t", "unknown-setting")
    se("set_duplicate_setting", "leading = 12pt\nalign = left\n\tleading = 13pt\n", 3, "l", "duplicate-setting")
    se("set_duplicate_before_value", "align = left\nalign = bogus\n", 2, "a", "duplicate-setting")
    pcase("set_ex17_bad_length_px", DOC1, "page-width = 200pt\nmargin-left = 20px\n",
          error="settings.cfg:2:15: bad-length")
    se("set_bad_length_space_unit", "body-size = 10 pt\n", 1, "10", "bad-length")
    se("set_bad_length_four_fraction_digits", "par-indent = 1.2345pt\n", 1, "1.", "bad-length")
    se("set_bad_length_plus_sign", "par-indent = +5pt\n", 1, "+", "bad-length")
    se("set_bad_length_leading_point", "par-space=.5pt\n", 1, ".", "bad-length")
    se("set_bad_length_trailing_point", "par-space = 5.pt\n", 1, "5", "bad-length")
    case("set_bad_length_empty", DOC1, "margin-top =\n", error="settings.cfg:1:13: bad-length")
    case("set_bad_length_empty_trailing_spaces", DOC1, "margin-top =   \n",
         error="settings.cfg:1:16: bad-length")
    se("set_bad_integer_fraction", "tolerance = 1.5\n", 1, "1", "bad-integer")
    se("set_bad_integer_plus", "widows = +2\n", 1, "+", "bad-integer")
    se("set_bad_boolean_yes", "hyphenate = yes\n", 1, "yes", "bad-boolean")
    se("set_bad_boolean_capital", "keep-with-next = On\n", 1, "O", "bad-boolean")
    se("set_bad_enum", "align = justified\n", 1, "j", "bad-enum")
    se("set_unknown_font", "body-font = times\n", 1, "times", "unknown-font")
    se("set_unknown_font_face_name", "heading-font = serif-bold\n", 1, "s", "unknown-font")
    se("set_unknown_patterns", "hyphen-patterns = French\n", 1, "F", "unknown-patterns")
    se("set_bad_value_tolerance", "tolerance = 10001\n", 1, "1", "bad-value")
    se("set_bad_value_body_size", "body-size = 999\n", 1, "9", "bad-value")
    se("set_bad_value_negative_margin", "margin-left = -1pt\n", 1, "-1", "bad-value")
    se("set_bad_value_page_width", "page-width = 35999\n", 1, "3", "bad-value")
    se("set_bad_value_hyphen_penalty", "hyphen-penalty = -10000\n", 1, "-1", "bad-value")
    se("set_bad_value_page_start", "page-start = 0\n", 1, "0", "bad-value")
    se("set_bad_value_leader_space", "toc-leader = . .\n", 1, ".", "bad-value")
    se("set_bad_value_leader_long", "toc-leader = 123456789\n", 1, "1", "bad-value")
    case("set_bad_value_leader_empty", DOC1, "toc-leader =\n", error="bad-value")
    se("set_bad_value_prefix_placeholder", "figure-caption-prefix = Fig {page}\n", 1, "F", "bad-value")
    se("set_bad_value_toc_title_placeholder", "toc-title = {title}\n", 1, "{", "bad-value")
    se("set_bad_escape", "header-left = a\\qb\n", 1, "\\", "bad-escape")
    se("set_bad_escape_trailing", "footer-left = page \\\n", 1, "\\", "bad-escape")
    se("set_unknown_placeholder", "footer-right = Page {pg}\n", 1, "{", "unknown-placeholder")
    se("set_unknown_placeholder_unclosed", "footer-right = {page\n", 1, "{", "unknown-placeholder")
    se("set_stray_brace", "header-center = a}\n", 1, "}", "stray-brace")
    se("set_escape_before_placeholder_check", "header-left = \\x{bad}\n", 1, "\\", "bad-escape")
    se("set_body_width_too_small",
       "page-width = 200pt\nmargin-left = 90pt\nmargin-right = 90pt\nleading = 13pt\n",
       3, "9", "bad-value")
    se("set_body_height_last_assigned",
       "margin-bottom = 50pt\npage-height = 120pt\nmargin-top = 40pt\nalign = left\n",
       3, "4", "bad-value")
    se("set_body_width_page_last",
       "margin-left = 100pt\nmargin-right = 100pt\npage-width = 230pt\n",
       3, "2", "bad-value")
    se("set_first_error_wins", "align = left\nwidows = x\norphans = y\n", 2, "x", "bad-integer")
    se("set_error_before_document", "line-skip = big\n", 1, "b", "bad-length",
       doc="@foo\n{z|bad}\n")
    case("set_missing_document", None, "page-width = oops\n", error="-:0:0: missing-document")
    case("set_missing_document_no_settings", None, None, error="-:0:0: missing-document",
         extra={"document.txt": "Not the document.\n"})


def g_config():
    case("cfg_units",
         para(11, 60),
         "page-width = 7in\npage-height = 25cm\nmargin-left = 1.5in\nmargin-top = 2pc\n"
         "margin-right = 12.7mm\nmargin-bottom = 54000\nbody-size = 10.5pt\n"
         "leading = 12.75pt\npar-indent = 0.333in\nline-skip = 0.5mm\n")
    case("cfg_comments_tabs_and_hash",
         "@h1 Start\n" + para(12, 80),
         "\t# a comment line\n  \t\n# another\npage-width\t=\t300pt\t\npage-height = 300pt\n"
         "header-left = A # B\nfooter-right =\t{page} # {pages}\t\n")
    case("cfg_defaults_letter_page", "@h1 Default page\n" + para(13, 400) + "\n" + para(14, 300))
    case("cfg_empty_settings_file", para(15, 50), "",
         extra={"settings.cfg.bak": "page-width = oops\n", "notes.cdx": "{z|ignored}\n"})
    case("cfg_only_comments", para(16, 50), "# nothing here\n\n   # still nothing\n")
    case("cfg_footer_baseline_default", "@h1 Footer\n" + para(17, 300),
         "page-height = 300pt\nfooter-center = {page} of {pages}\n")
    case("cfg_negative_hyphen_penalty", para(18, 120),
         med("hyphen-penalty = -500\nex-hyphen-penalty = -100"))
    case("cfg_negative_length_allowed_zero_margins", para(19, 120),
         "page-width = 150pt\npage-height = 150pt\nmargin-top = 0\nmargin-bottom = 0\n"
         "margin-left = 0pt\nmargin-right = 0.0pt\n")
    case("cfg_fraction_rounding", para(20, 80),
         "page-width = 211.111pt\nmargin-left = 1.1mm\nmargin-right = 0.7cm\nbody-size = 9.999pt\n"
         "leading = 11.001pt\npar-indent = 1.5mm\n")
    case("cfg_big_body_size", "@h2 Large\n" + para(21, 60), "body-size = 18pt\nleading = 22pt\n")
    case("cfg_line_skip_dominates", para(22, 120),
         med("leading = 4pt\nline-skip = 2pt"))
    case("cfg_par_space", para(23, 40) + "\n" + para(24, 40) + "\n" + para(25, 40),
         med("par-space = 9pt\npar-indent = 0"))


# ---------------------------------------------------------------------------
# document errors
# ---------------------------------------------------------------------------

def g_errors():
    def de(name, doc, line, sub, code, nth=0, cfg=None, **kw):
        case(name, doc, cfg, error=derr(doc, line, sub, code, nth), **kw)

    pcase("err_ex17_unknown_inline", "@h1 Title\n{z|oops}\n", SMALL,
          error="document.cdx:2:1: unknown-inline")
    de("err_unknown_block", "Para.\n\n@foo bar\n", 3, "@", "unknown-block")
    de("err_unknown_block_h1x", "  @h1x Title\n", 1, "@", "unknown-block")
    de("err_unknown_block_star_x", "@h2*x T\n", 1, "@", "unknown-block")
    de("err_li_outside_list", "Text.\n\n@li item\n", 3, "@", "block-not-allowed")
    de("err_hrule_outside_table", "@hrule\n", 1, "@", "block-not-allowed")
    de("err_doc_not_first", "Para.\n@doc\n@end\n", 2, "@", "block-not-allowed")
    de("err_toc_after_heading", "@h1 A\n@toc\n", 2, "@", "block-not-allowed")
    de("err_toc_third_block", "@doc\ntitle = T\n@end\n@h1 A\n@toc\n", 5, "@", "block-not-allowed")
    de("err_duplicate_toc", "@toc\n@toc\n", 2, "@", "duplicate-toc")
    de("err_block_in_table", "@table cols=1\na\n@rule\n@end\n", 3, "@", "block-not-allowed")
    de("err_block_in_figure", "@fig height=10pt\nCap\n@q\n@end\n@end\n", 3, "@", "block-not-allowed")
    de("err_block_in_doc", "@doc\n@h1 X\n@end\n", 2, "@", "block-not-allowed")
    de("err_doc_bad_syntax", "@doc\ntitle: X\n@end\n", 2, "t", "bad-syntax")
    de("err_unknown_name_in_doc", "@doc\n@foo\n@end\n", 2, "@", "unknown-block")
    de("err_unknown_meta", "@doc\n  subject = X\n@end\n", 2, "s", "unknown-meta")
    de("err_duplicate_meta", "@doc\ntitle = A\ntitle = B\n@end\n", 3, "t", "duplicate-meta")
    de("err_li_in_quote_in_item", "@ul\n@li a\n@q\n@li b\n@end\n@end\n", 4, "@", "block-not-allowed")
    de("err_text_before_first_li", "@ul\n\nloose text\n@li a\n@end\n", 3, "l", "text-not-allowed")
    de("err_unexpected_end", "Para.\n\n  @end\n", 3, "@", "unexpected-end")
    case("err_missing_end_nested", "@q\nText.\n@ul\n@li a\n", error="document.cdx:5:1: missing-end")
    case("err_missing_end_pre", "@pre\ncode\n  @end x\n", error="document.cdx:4:1: missing-end")
    de("err_bad_attribute_unknown", "@ol begin=3\n@li a\n@end\n", 1, "b", "bad-attribute")
    de("err_bad_attribute_repeated", "@ol start=2 start=3\n", 1, "s", "bad-attribute", nth=1)
    de("err_bad_attribute_word", "@q please\n", 1, "p", "bad-attribute")
    de("err_bad_attribute_after_end", "@q\nText.\n@end q\n", 3, "q", "bad-attribute")
    de("err_bad_attribute_name_first", "@table cols=0 foo=1\n", 1, "f", "bad-attribute")
    de("err_missing_attribute_table", "Text.\n\n  @table align=ll\n", 3, "@", "missing-attribute")
    de("err_missing_attribute_fig", "@fig width=10pt\nx\n@end\n", 1, "@", "missing-attribute")
    de("err_missing_before_pair_check", "@table align=lll\n", 1, "@", "missing-attribute")
    de("err_missing_before_value_check", "@table align=xyz\n", 1, "@", "missing-attribute")
    de("err_value_shape_before_missing", "@table align=\"ll\n", 1, "\"", "bad-attribute-value")
    de("err_bad_value_start_zero", "@ol start=0\n", 1, "0", "bad-attribute-value")
    de("err_bad_value_length_unit", "@vspace height=12px\n", 1, "1", "bad-attribute-value")
    de("err_bad_value_negative_height", "@fig height=-1pt\n", 1, "-", "bad-attribute-value")
    de("err_bad_value_cols", "@table cols=21\n", 1, "2", "bad-attribute-value")
    de("err_bad_value_align_letter", "@table cols=2 align=lx\n", 1, "lx", "bad-attribute-value")
    de("err_bad_value_align_count", "@table cols=3 align=lr\na|b|c\n@end\n", 1, "lr", "bad-attribute-value")
    de("err_bad_value_unterminated_quote", '@toc title="Contents\n', 1, '"', "bad-attribute-value")
    de("err_bad_value_bare_then_quote", '@ol start=5"x"\n', 1, "5", "bad-attribute-value")
    de("err_bad_value_block_font", "@block font=times\n@end\n", 1, "times", "bad-attribute-value")
    de("err_bad_value_block_size", "@block size=999\n@end\n", 1, "9", "bad-attribute-value")
    case("err_quoted_value_is_valid", 'A.\n@vspace height="12pt"\nB.\n', SMALL)
    de("err_cell_count", "@table cols=3\na | b | c\na | b\n@end\n", 3, "a", "cell-count")
    de("err_cell_count_before_inline", "@table cols=2\n{z|a} | b | c\n@end\n", 2, "{", "cell-count")
    de("err_text_inside_table_ok_then_bad_escape", "@table cols=1\na\\qb\n@end\n", 2, "\\", "bad-escape")
    de("err_unknown_inline", "Some {x|text}.\n", 1, "{", "unknown-inline")
    de("err_unclosed_inline_innermost", "A {b|bold {i|both} and {m|mono\nmore text.\n", 1, "{m", "unclosed-inline")
    de("err_unclosed_inline_outer", "A {b|bold {i|both} and\nmore text.\n", 1, "{b", "unclosed-inline")
    de("err_stray_brace", "Text } here.\n", 1, "}", "stray-brace")
    de("err_bad_escape", "Path a\\b.\n", 1, "\\", "bad-escape")
    de("err_bad_escape_end_of_block", "Trailing \\\n", 1, "\\", "bad-escape")
    de("err_nested_footnote", "A{n|b{n|c}}\n", 1, "{", "nested-footnote", nth=1)
    de("err_footnote_in_heading", "@h1 Title{n|x}\n", 1, "{", "footnote-not-allowed")
    de("err_footnote_in_cell_splits_row", "@table cols=1\nCell{n|x}\n@end\n", 2, "C", "cell-count")
    de("err_style_in_cell_splits", "@table cols=3\n{b|x} | y\n@end\n", 2, "{", "unknown-inline")
    de("err_footnote_in_caption", "@fig height=10pt\nCap{n|x}\n@end\n", 2, "{", "footnote-not-allowed")
    de("err_inline_in_continuation", "First line ok.\nsecond {q|bad}.\n", 2, "{", "unknown-inline")
    de("err_unicode_column", "Ünïcödé — {z|x}\n", 1, "{", "unknown-inline")
    de("err_first_error_wins", "{z|a}\n\n@foo\n", 1, "{", "unknown-inline")
    de("err_attribute_before_items", "@ol start=x\n@li {z|a}\n@end\n", 1, "x", "bad-attribute-value")
    de("err_li_continuation_inline", "@ul\n@li ok\ncontinued {z|q}\n@end\n", 3, "{", "unknown-inline")
    de("err_toc_title_ok_then_unknown", '@toc title="A {z} B"\n@foo\n', 2, "@", "unknown-block")
    de("err_block_inside_pre_is_text", "@pre\n@foo\n@end\n@bar\n", 4, "@", "unknown-block")
    de("err_figure_caption_inline", "@fig height=5pt\n\nok\n\nbad }\n@end\n", 5, "}", "stray-brace")
    de("err_heading_star_attr_text_ok_then", "@h1* x=1\n@hrule\n", 2, "@", "block-not-allowed")


# ---------------------------------------------------------------------------
# inline markup, hyphenation, line breaking, alignment
# ---------------------------------------------------------------------------

def g_inline():
    case("inl_styles",
         "Plain {b|bold} {i|italic} {b|{i|bold italic}} {m|mono text} and more.\n", SMALL)
    case("inl_styles_sans_body",
         "Plain {b|bold} {i|italic} {b|{i|both}} {m|mono {b|still mono}} end.\n",
         small("body-font = sans"))
    case("inl_styles_mono_body",
         "Mono {b|bold} {i|italic} words in a mono body never stretch.\n",
         small("body-font = mono"))
    case("inl_sizes",
         "Normal {+|bigger {+|biggest}} and {-|smaller {-|tiny {-|tinier}}} text.\n", SMALL)
    case("inl_size_steps_odd",
         "{-|{-|{-|{-|{-|{-|deep}}}}}} {+|{+|{+|{+|high}}}} x\n", small("body-size = 7pt"))
    case("inl_escapes",
         "Braces \\{ and \\} bar \\| slash \\\\ at \\@ tilde \\~ and \\-done.\n", SMALL)
    case("inl_escaped_at_line_start", "\\@h1 is not a heading here.\n\\{b|x\\} either.\n", SMALL)
    case("inl_nbsp_and_rigid_space",
         "Mr.~Smith and Dr.\\ Who went to~the~very~end of~it with Ms.~Jones~again.\n",
         small("align = left"))
    case("inl_nbsp_prevents_break",
         "aaa~bbb~ccc~ddd~eee~fff~ggg~hhh~iii~jjj~kkk~lll~mmm~nnn~ooo~ppp~qqq end\n", SMALL)
    case("inl_whitespace_collapse",
         "   lots    of   spaces   \n   and more   \n  on three    lines   \n", SMALL)
    case("inl_sentence_rule",
         "End. Next! Why? J. Smith met F. Scott (really.) \"Quoted.\" ’Curly.’ "
         "etc. and A.B. ok.) [x.] done? Yes!) {b|bold.} next.\n", small("align = left"))
    case("inl_sentence_rule_justified",
         "One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten. Eleven. "
         "Twelve. Thirteen. Fourteen. Fifteen. Sixteen.\n", SMALL)
    case("inl_sentence_mark_and_disc",
         "Word.{n|note} next and word.\\- next and word\\-. next and .start x.~y.\\ z\n",
         small("align = left"))
    case("inl_sentence_text_start", ". Leading dot. A. B. c.\n", small("align = left"))
    case("inl_discretionary",
         "Supercalifragilistic\\-expialidocious and anti\\-dis\\-establish\\-ment\\-arian words.\n",
         small("tolerance = 10000\npar-indent = 0"))
    case("inl_core_hyphens",
         "self-contained co-operation well-known state-of-the-art x-ray e-mail-like words\n",
         small("par-indent = 0"))
    case("inl_backslash_line_join", "abc\\\ndef ghi\\\n  jkl\n", SMALL)
    case("inl_unicode", "Café naïve façade — “quotes” ‘single’ … ½ ∑ 漢字 Zoë.\n", SMALL)
    case("inl_kerning", "AVATAR To Ty We Yo LT AWAY Fa F. VAT Tu Te Ta P. Y, LYNX\n", SMALL)
    case("inl_mark_styles",
         "{b|Bold{n|first note}} {i|it{n|second}} {+|big{n|third}} plain.\n", SMALL)
    case("inl_footnote_style_fresh",
         "{b|bold {n|plain note {i|italic part}} still bold}\n", SMALL)
    case("inl_glue_style_first_space",
         "{b|alpha }beta {+|gamma  }{-|delta} epsilon\n", small("align = left"))
    case("inl_empty_styles", "{b|}x{i|} y {m|} z{+|}{-|}\n", SMALL)
    case("inl_quote_char_escape_output", "He said \"hi\" and \\\\ back.\n", SMALL)
    case("inl_bar_is_ordinary", "a|b {b|c|d} | e\n", SMALL)
    case("inl_mixed_long",
         wrap(" ".join("{b|%s} {i|%s} %s {m|%s}" % tuple(prose(30 + i, 4).split(" ")[:4])
                       for i in range(12))), MED)


def g_hyphen():
    words = ("typesetting national introduction algorithm paragraph hyphenation "
             "interesting conversation information government important "
             "development international experience university community")
    case("hyph_english_narrow", words + ".\n", small("tolerance = 10000\npar-indent = 0\nmargin-right = 70pt"))
    case("hyph_minimal_set", "hyphen exception better rabbit abbey letter nation "
         "terrible matters hyphenation exceptional\n",
         small("tolerance = 10000\nhyphen-patterns = minimal\npar-indent = 0\nmargin-right = 80pt"))
    case("hyph_off", words + ".\n", small("tolerance = 10000\nhyphenate = off\npar-indent = 0\nmargin-right = 70pt"))
    case("hyph_exceptions", "algorithm typeset codexa paragraph through strength "
         "straight thought bright Algorithm TYPESET\n",
         small("tolerance = 10000\npar-indent = 0\nmargin-right = 90pt"))
    case("hyph_punctuation_core",
         "(introduction), “national”—winter's 123abc abc123 'typesetting' "
         "national-introduction 9-to-5 (winter-time) and other ordinary words.\n",
         med("tolerance = 10000\npar-indent = 0"))
    case("hyph_case_mapping", "INTRODUCTION Typesetting NaTiOnAl HYPHENATION Ångström and some "
         "more ordinary words to fill the line nicely\n", small("tolerance = 10000\npar-indent = 0"))
    case("hyph_mono_never", "{m|typesetting national introduction} typesetting\n",
         small("tolerance = 10000\npar-indent = 0\nmargin-right = 100pt"))
    case("hyph_short_words", "a an ant into winter be my typo it is on\n",
         small("tolerance = 10000\npar-indent = 0\nmargin-right = 120pt"))
    explicit = ("typeset\\-ting introduc\\-tion national\\-ity self-\\-made and then some more "
                "ordinary words go here\n")
    case("hyph_explicit_overrides", explicit,
         small("tolerance = 10000\npar-indent = 0\nmargin-right = 40pt"))
    case("hyph_explicit_with_gate_off", explicit,
         small("tolerance = 10000\nhyphenate = off\npar-indent = 0\nmargin-right = 40pt"))
    case("hyph_penalty_settings", para(40, 80),
         small("hyphen-penalty = 9999\nex-hyphen-penalty = -9999"))
    case("hyph_negative_penalty", para(41, 80), small("hyphen-penalty = -300"))
    case("hyph_double_final_zero", para(42, 120),
         small("double-hyphen-demerits = 0\nfinal-hyphen-demerits = 0\nhyphen-penalty = 0"))
    case("hyph_double_final_high", para(42, 120),
         small("double-hyphen-demerits = 1000000\nfinal-hyphen-demerits = 1000000\nhyphen-penalty = 0"))
    case("hyph_in_footnote_and_caption",
         "Text{n|typesetting national introduction international hyphenation "
         "interesting conversation}\n@fig height=5pt width=120pt\ntypesetting "
         "national introduction international\n@end\n", merge(TALL, "tolerance = 10000"))
    case("hyph_many_points_one_run", "Representativeness and telecommunications "
         "internationalization.\n", SMALL)


def g_breaking():
    case("brk_tolerance_low", para(50, 150), med("tolerance = 100"))
    case("brk_tolerance_high", para(50, 150), med("tolerance = 10000"))
    case("brk_tolerance_zero_wide", para(51, 300), "tolerance = 0\n")
    case("brk_narrow_overfull_pass2",
         "@block indent=100pt right-indent=30pt\nincomprehensibilities "
         "counterrevolutionaries uncharacteristically\n@end\n", SMALL)
    case("brk_line_penalty_zero", para(52, 120), med("line-penalty = 0"))
    case("brk_line_penalty_max", para(52, 120), med("line-penalty = 10000"))
    case("brk_adj_demerits_zero", para(53, 120), med("adj-demerits = 0"))
    case("brk_adj_demerits_max", para(53, 120), med("adj-demerits = 1000000"))
    case("brk_ragged_stretch_zero", para(54, 60), small("align = left\nragged-stretch = 0"))
    case("brk_ragged_stretch_max", para(54, 60), small("align = right\nragged-stretch = 100"))
    case("brk_empty_lists", "@ul\n@li\n@li {b|}\n@end\n@h2\n@h1*\n", SMALL)
    case("brk_long_paragraph", para(55, 500), MED)
    case("brk_single_long_word", "Pneumonoultramicroscopicsilicovolcanoconiosis\n",
         small("par-indent = 0\nmargin-right = 100pt"))
    case("brk_unstretchable_mono", "{m|a b c d e f g h i j k l m n o p q r s t u v w x y z "
         "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp}\n", SMALL)
    case("brk_exact_fit", "@block indent=0pt right-indent=24.65pt\nThe quick brown fox "
         "jumps over the lazy dog again and again.\n@end\n", small("par-indent = 0"))
    case("brk_tolerance_zero_narrow_words", para(56, 60),
         small("tolerance = 0\nhyphenate = off"))


def g_align():
    text = para(60, 70)
    case("algn_justify", text, SMALL)
    case("algn_left", text, small("align = left"))
    case("algn_right", text, small("align = right"))
    case("algn_center", text, small("align = center"))
    case("algn_center_odd_offset", "Odd widths x.\n\nA b.\n", small("align = center\npar-indent = 1"))
    case("algn_heading_aligns",
         "@h1 Centred heading text\n@h2 Another one here\nBody.\n",
         small("heading-align = center"))
    case("algn_heading_right", "@h1 Right\n@h3 Also right but longer heading words\n",
         small("heading-align = right"))
    case("algn_heading_justify", "@h1 A justified heading that is long enough to wrap twice\n",
         small("tolerance = 10000\nheading-align = justify"))
    case("algn_block_overrides",
         "@block align=right\n" + para(61, 30) + "@end\n@block align=center\n" + para(62, 30)
         + "@end\n@block align=left\n" + para(63, 30) + "@end\n", MED)
    case("algn_par_indent_zero_right", text, small("align = right\npar-indent = 0"))
    case("algn_large_par_indent", text, small("par-indent = 100pt"))


# ---------------------------------------------------------------------------
# headings, lists, quotes, groups, preformatted text
# ---------------------------------------------------------------------------

def g_headings():
    case("head_all_levels",
         "@h1 One\nText.\n@h2 Two\nText.\n@h3 Three\nText.\n@h4 Four\nText.\n"
         "@h2 Two again\n@h3 Three again\n@h1 Uno\n@h4 Deep four\n", TALL)
    case("head_unnumbered_star",
         "@h1 First\n@h1* Preface\n@h2* Note\n@h1 Second\n@h2 Sub\n", TALL)
    case("head_number_off",
         "@h1 First\n@h2 Sub\nText.\n", small("heading-number = off"))
    case("head_counters_from_zero", "@h3 Deep first\n@h4 Deeper\n@h2 Middle\n@h4 Skip\n", TALL)
    case("head_styles_settings",
         "@h1 Serif italic\n@h2 Not bold\n",
         small("heading-font = serif\nheading-italic = on\nheading-bold = off"))
    case("head_mono_font", "@h2 Mono heading\n", small("heading-font = mono"))
    case("head_number_gap", "@h1 Gap\n@h2 Gap two\n", small("heading-number-gap = 0\nh2-size = 16pt"))
    case("head_h1_newpage",
         "Intro.\n@h1 Chapter\nText.\n@h2 Sub\nText.\n@h1 Next\nMore.\n@newpage\n@h1 After newpage\n",
         small("h1-newpage = on"))
    case("head_h1_newpage_first", "@h1 Very first\nText.\n", small("h1-newpage = on"))
    case("head_long_wraps", "@h1 A heading so long that it must wrap onto further lines "
         "whatever happens\nBody text.\n", SMALL)
    case("head_inline_styles", "@h2 With {i|italic} and {m|mono} and {-|small}\n", SMALL)
    case("head_attr_like_text", "@h1 x=1 Title\n@h2*   spaced   out   \n", SMALL)
    case("head_sizes_and_space",
         "Para.\n@h1 A\n@h2 B\n@h3 C\n@h4 D\nPara.\n",
         small("h1-size = 10pt\nh2-size = 30pt\nh3-leading = 40pt\nh4-space-before = 0\n"
               "h1-space-after = 0\nh2-space-before = 25pt\nh3-space-after = 1pt\n"
               "h4-leading = 1pt\nh1-leading = 1pt"))
    case("head_hyphenated_text", "@h1 Internationalization of typesetting and the conversation\n",
         med("tolerance = 10000"))
    case("head_text_after_heading_is_paragraph", "@h2 Title\nFirst line\ncontinues here.\n", SMALL)


def g_lists():
    case("list_ul_depths",
         "@ul\n@li one\n@ul\n@li two\n@ul\n@li three\n@ul\n@li four\n@end\n@end\n@end\n@end\n",
         TALL)
    case("list_ol_depths",
         "@ol\n@li one\n@ol\n@li two\n@ol\n@li three\n@ol\n@li four\n@end\n@end\n@end\n@end\n",
         TALL)
    case("list_ol_alpha_wrap",
         "@ol\n@li x\n@ol start=26\n@li z\n@li aa\n@li ab\n@end\n@li y\n@ol start=52\n"
         "@li az\n@li ba\n@end\n@end\n", TALL)
    case("list_ol_roman",
         "@ol\n@li a\n@ol\n@li b\n@ol start=1994\n@li mcmxciv\n@li mcmxcv\n@end\n@end\n"
         "@ol start=3999\n@li big\n@end\n@end\n", TALL)
    case("list_ol_start_big_decimal", "@ol start=99998\n@li one\n@li two\n@li three\n@end\n", SMALL)
    case("list_continuation_and_blocks",
         "@ul\n@li First item text\ncontinues here on a second source line.\n"
         "A paragraph inside the item? No, still continuation.\n\nA real paragraph inside the item.\n"
         "@pre\ncode in item\n@end\n@q\nQuoted in item.\n@end\n@li Second.\n@end\n", TALL)
    case("list_table_in_item",
         "@ol\n@li Table follows.\n@table cols=2 align=lr\nA | 1\nB | 22\n@end\n@li After.\n@end\n",
         TALL)
    case("list_spacing_settings",
         "Before.\n@ul\n@li a\n@li b\n@ul\n@li c\n@end\n@li d\n@end\nAfter.\n",
         small("list-space = 10pt\nlist-item-space = 3pt\nlist-indent = 30pt\nlist-marker-gap = 1pt"))
    case("list_empty_items", "@ol\n@li\n@li\n@li text\n@end\n", SMALL)
    case("list_empty_list", "Para.\n@ul\n\n@end\nAfter.\n", SMALL)
    case("list_long_items", "@ul\n@li " + prose(70, 60) + "\n@li " + prose(71, 40) + "\n@end\n", TALL)
    case("list_marker_sans_body", "@ol\n@li a\n@li b\n@end\n", small("body-font = sans\nbody-size = 12pt"))
    case("list_marker_in_block_mono",
         "@block font=mono size=8pt\n@ul\n@li mono item\n@ol start=7\n@li x\n@end\n@end\n@end\n", SMALL)
    case("list_empty_li_then_continuation", "@ul\n@li\nThis is a paragraph in an empty-text item.\n@end\n",
         SMALL)
    case("list_many_items_pages",
         "@ol\n" + "".join("@li %s\n" % prose(80 + i, 8) for i in range(40)) + "@end\n", SMALL)


def g_quotes():
    case("quote_simple", "Before.\n@q\n" + para(90, 30) + "@end\nAfter.\n", SMALL)
    case("quote_nested", "@q\nOuter.\n@q\nInner " + prose(91, 20) + "\n@q\nInnermost.\n@end\n@end\n@end\n",
         TALL)
    case("quote_space_max", "Para.\n@q\nQuoted.\n@end\nPara.\n",
         small("par-space = 4pt\nquote-space = 10pt\nquote-indent = 5pt"))
    case("quote_empty", "Para.\n@q\n@end\nAfter.\n", SMALL)
    case("quote_with_list_and_heading",
         "@q\n@h3 Quoted heading\n@ul\n@li item\n@end\n" + para(92, 20) + "@end\n", TALL)
    case("quote_vspace_registers", "A.\n@vspace height=6pt\n@q\n@vspace height=6pt\nB.\n@end\nC.\n",
         small("par-space = 2pt"))


def g_groups():
    case("blk_all_attributes",
         "@block align=center indent=20pt right-indent=10pt font=sans size=12pt leading=20pt\n"
         + para(100, 40) + "@end\nAfter.\n", MED)
    case("blk_nested", "@block indent=10pt\n@block indent=10pt font=mono\n" + para(101, 20)
         + "@end\nMiddle.\n@end\n", MED)
    case("blk_quoted_values", '@block align="right" size="9pt"\n' + para(102, 25) + "@end\n", MED)
    case("blk_affects_headings_lists_tables",
         "@block indent=30pt size=8pt font=sans\n@h2 Heading not affected\n@ul\n@li listed\n@end\n"
         "@table cols=2\na | b\n@end\n@rule\n@end\n", MED)
    case("blk_size_affects_glue_and_marks", "@block size=14pt leading=16pt\nBig text{n|small note} here.\n@end\n",
         SMALL)
    case("blk_empty", "A.\n@block\n@end\nB.\n", SMALL)
    case("blk_right_indent_only", "@block right-indent=60pt\n" + para(103, 30) + "@end\n",
         small("tolerance = 10000\npar-indent = 0"))


def g_pre():
    case("pre_blank_and_trailing",
         "@pre\n  first   \n\n\nafter blanks \n   \n@end\nText.\n", SMALL)
    case("pre_overfull", "@pre\n" + "x" * 40 + "\nshort\n@end\n", SMALL)
    case("pre_no_markup", "@pre\n{z|x} \\q } {b|not bold} ~ \\- @foo\n@end\n", SMALL)
    case("pre_indented_terminator", "@pre\ncode\n   @end   \nAfter.\n", SMALL)
    case("pre_empty", "Before.\n@pre\n@end\nAfter.\n", SMALL)
    case("pre_settings", "@pre\nserif pre line\ntypesetting hyphenation\n@end\n",
         small("pre-font = serif\npre-size = 11pt\npre-leading = 15pt\npre-indent = 20pt\npre-space = 0"))
    case("pre_only_blank_lines", "@pre\n\n\n@end\n", SMALL)
    case("pre_unicode", "@pre\nnaïve “x” — 漢字\n\t\n@end\n".replace("\t\n", ""), SMALL)
    case("pre_across_pages", "@pre\n" + "".join("line %d of the listing\n" % i for i in range(1, 25))
         + "@end\n", SMALL)
    case("pre_in_quote_and_list", "@q\n@pre\nquoted code\n@end\n@end\n@ul\n@li x\n@pre\nlisted\n@end\n@end\n",
         SMALL)


# ---------------------------------------------------------------------------
# tables, footnotes, figures
# ---------------------------------------------------------------------------

def g_tables():
    case("tbl_min_branch",
         "@table cols=3\nextraordinarily long words | internationalization typesetting | "
         "counterrevolutionary characteristically\nx | y | z\n@end\n", SMALL)
    case("tbl_hrules_everywhere",
         "@table cols=2 align=cr\n@hrule\nHead | Num\n@hrule\n@hrule\nA | 1\nB | 2\n@hrule\n@end\n", SMALL)
    case("tbl_only_hrule", "@table cols=2\n@hrule\n@end\n", SMALL)
    case("tbl_empty_table", "Before.\n@table cols=4\n@end\nAfter.\n", SMALL)
    case("tbl_empty_cells_and_rows", "@table cols=3 align=lcr\n | | \na |  | c\n | b | \n@end\n", SMALL)
    case("tbl_multiline_cells",
         "@table cols=2 align=lc\nA cell that has rather many words in it so that it wraps | short\n"
         "x | another fairly long cell value that also needs to wrap\n@end\n", SMALL)
    case("tbl_styles_and_escapes",
         "@table cols=3 align=rcl\nBold | it \\| bar | mono\nbig | a~b\\ c | \\{x\\} dis\\-cre\\-tion\n@end\n",
         SMALL)
    case("tbl_settings",
         "@table cols=2\nA | B\n@hrule\nC | D\nE | F\n@end\nAfter.\n",
         small("table-col-gap = 20pt\ntable-row-space = 5pt\ntable-rule-space = 7pt\n"
               "table-rule-thickness = 2pt\ntable-space = 15pt\ntable-leading = 20pt"))
    case("tbl_in_quote_and_block",
         "@q\n@table cols=2\nquoted | table\n@end\n@end\n@block indent=40pt size=8pt font=sans\n"
         "@table cols=2 align=rr\nsmall | sans\n@end\n@end\n", SMALL)
    case("tbl_twelve_columns",
         "@table cols=12 align=lcrlcrlcrlcr\n" +
         "".join(" | ".join(str((r * 12 + c) * 37 % 1000) for c in range(12)) + "\n" for r in range(8)) +
         "@end\n", "page-width = 600pt\nmargin-left = 20pt\nmargin-right = 20pt\n")
    case("tbl_twelve_columns_squeezed",
         "@table cols=12\n" + "".join(" | ".join(prose(200 + r * 12 + c, 3) for c in range(12)) + "\n"
                                      for r in range(5)) + "@end\n", "")
    case("tbl_across_pages",
         "@table cols=3 align=lrr\n" + "".join("Row %d | %d | %d.%02d\n" % (i, i * i, i * 7, i % 100)
                                              for i in range(1, 30)) + "@end\n", SMALL)
    case("tbl_block_size_in_cells", "@block size=14pt\n@table cols=2\nBig | cells\n@end\n@end\n"
         "@table cols=2\nnormal | cells\n@end\n", SMALL)
    case("tbl_hyphen_min", "@table cols=2\ntypesetting internationalization | x\n"
         "conversation | y\n@end\n", small("margin-right = 120pt"))
    case("tbl_single_column_spaces", "@table cols=1 align=c\n   padded   cell   \n\\ escaped space\n@end\n", SMALL)


def g_footnotes():
    case("fn_two_on_one_line", "Alpha{n|First note.} beta{n|Second note.} gamma.\n", SMALL)
    case("fn_long_footnote_wraps", "Text{n|" + prose(110, 60) + "} more text.\n", TALL)
    split_doc = (para(111, 20).rstrip("\n") + "{n|Short note.} more words here and there{n|"
                 + prose(112, 40) + "} " + para(113, 40))
    case("fn_split_min_split_1", split_doc, SMALL)
    case("fn_split_min_split_3", split_doc, small("footnote-min-split = 3"))
    split_doc2 = (para(111, 40).rstrip("\n") + "{n|Short note.} more words here and there{n|"
                  + prose(112, 70) + "} " + para(113, 40))
    case("fn_split_min_split_2_long", split_doc2, small("footnote-min-split = 2"))
    case("fn_split_min_split_100", split_doc2, small("footnote-min-split = 100"))
    case("fn_multi_group_carry",
         para(114, 60).rstrip("\n") + "{n|" + prose(115, 50) + "}{n|" + prose(116, 30) + "}{n|"
         + prose(117, 20) + "} " + para(118, 30), SMALL)
    case("fn_max_height_small",
         para(119, 50).rstrip("\n") + "{n|" + prose(120, 60) + "} " + para(121, 100),
         small("footnote-max-height = 25pt"))
    case("fn_eight_notes", " ".join("Word%d{n|Note number %d.}" % (i, i) for i in range(1, 9)) + "\n", SMALL)
    case("fn_settings",
         "Alpha{n|A note with {b|bold} and {i|italic} text.} beta{n|Another.}\n",
         small("footnote-font = sans\nfootnote-size = 9pt\nfootnote-leading = 13pt\n"
               "footnote-indent = 20pt\nfootnote-mark-gap = 5pt\nfootnote-mark-size = 8pt\n"
               "footnote-mark-raise = 0\nfootnote-item-space = 6pt\nfootnote-rule-width = 0\n"
               "footnote-rule-thickness = 1pt\nfootnote-space-before = 10pt\n"
               "footnote-space-after = 1pt\nmark-size = 5pt\nmark-raise = 5pt"))
    case("fn_in_list_quote_block",
         "@ul\n@li Item{n|List note.}\n@end\n@q\nQuote{n|Quote note.}\n@end\n"
         "@block size=12pt\nBig{n|Block note.}\n@end\n", SMALL)
    case("fn_empty_note", "Empty{n|} note and{n|   } spaces.\n", SMALL)
    case("fn_mark_at_line_start", "{n|Starts with a note.}First word.\n", SMALL)
    case("fn_with_figure_same_page",
         "Alpha{n|Note on a page with a figure.}\n@fig height=20pt\nCap.\n@end\n" + para(122, 120), SMALL)
    case("fn_many_across_pages",
         "".join(para(130 + i, 25).rstrip("\n") + "{n|" + prose(150 + i, 5 + 7 * (i % 4)) + "}\n\n"
                 for i in range(14)), SMALL)
    case("fn_page_with_only_footnotes",
         "Short{n|" + prose(170, 200) + "}\n", small("footnote-max-height = 30pt"))
    case("fn_unicode_and_sentences", "Ref{n|Naïve café. J. Smith wrote it. Done!}\n", SMALL)
    case("fn_justify_ragged", "A{n|" + prose(171, 40) + "}\n", small("align = center"))


def g_figures():
    case("fig_width_attr", "@fig height=20pt width=80pt\nA narrower caption that must wrap under the box.\n"
         "@end\nText.\n", SMALL)
    case("fig_width_setting", "@fig height=20pt\nCaption one.\n@end\n@fig height=10pt width=0\nCaption two.\n@end\n"
         "Body.\n", small("figure-width = 100pt"))
    case("fig_frame_off_prefix_empty", "@fig height=15pt\nNo frame.\n@end\nText.\n",
         small("figure-frame = off\nfigure-caption-prefix ="))
    case("fig_prefix_custom", "@fig height=15pt\nCustom prefix.\n@end\nX.\n",
         small("figure-caption-prefix = Fig. \\{A\\}\nfigure-caption-gap = 10pt\n"
               "figure-caption-space = 1pt"))
    case("fig_caption_aligns", "@fig height=5pt\n" + prose(180, 25) + "\n@end\n@fig height=5pt\n"
         + prose(181, 25) + "\n@end\nX.\n", small("figure-caption-align = justify"))
    case("fig_caption_left", "@fig height=5pt width=100pt\n" + prose(182, 20) + "\n@end\nX.\n",
         small("figure-caption-align = left\nfigure-caption-font = sans\nfigure-caption-size = 8pt\n"
               "figure-caption-leading = 9pt"))
    case("fig_caption_right", "@fig height=5pt width=120pt\n" + prose(183, 20) + "\n@end\nX.\n",
         small("figure-caption-align = right"))
    case("fig_queue_min_body", "".join("@fig height=12pt\nFigure %d.\n@end\n" % i for i in range(5))
         + para(184, 200), SMALL)
    case("fig_queue_min_body_large", "".join("@fig height=8pt\nF%d.\n@end\n" % i for i in range(4))
         + para(185, 200), small("float-min-body = 60pt\nfloat-space-after = 2pt"))
    case("fig_after_last_page", "Only text.\n" + "".join("@fig height=25pt\nTail %d.\n@end\n" % i
                                                         for i in range(4)), SMALL)
    case("fig_empty_caption_blank_lines", "@fig height=10pt\n\n\n@end\nX.\n", SMALL)
    case("fig_caption_multiline_source", "@fig height=10pt\nfirst line\n\nsecond line\n  third {b|bold}\n@end\nX.\n",
         SMALL)
    case("fig_tall_alone", "Start.\n@fig height=60pt\nBig.\n@end\n" + para(186, 80), SMALL)
    case("fig_zero_height", "@fig height=0pt\nZero.\n@end\nX.\n", SMALL)
    case("fig_in_list_and_quote", "@ul\n@li a\n@fig height=5pt\nIn list.\n@end\n@end\n@q\n@fig height=5pt\n"
         "In quote.\n@end\n@end\n" + para(187, 30), SMALL)
    case("fig_with_newpage", "A.\n@fig height=10pt\nOne.\n@end\n@newpage\nB.\n@fig height=10pt\nTwo.\n@end\n"
         "@newpage\nC.\n", SMALL)


# ---------------------------------------------------------------------------
# pagination, headers and footers, the table of contents, whole documents
# ---------------------------------------------------------------------------

def g_pages():
    case("page_empty_document", "", SMALL, layout="layout 1\npages 0\n",
         report={"pages": 0, "lines": 0, "total-demerits": 0})
    case("page_blank_lines_only", "   \n\n  \n", SMALL, layout="layout 1\npages 0\n")
    case("page_doc_and_toc_only", "@doc\ntitle = T\n@end\n@toc\n", SMALL)
    case("page_newpage_only", "@newpage\n@newpage\n", SMALL, layout="layout 1\npages 0\n")
    case("page_trailing_and_double_newpage", "A.\n@newpage\n@newpage\n\nB.\n@newpage\n@vspace height=5pt\n",
         SMALL, report={"pages": 2})
    case("page_leading_vspace_dropped", "@vspace height=30pt\nA.\n@newpage\n@vspace height=30pt\nB.\n", SMALL)
    case("page_vspace_accumulates", "A.\n@vspace height=6pt\n@vspace height=6pt\nB.\n", small("par-space = 6pt"))
    case("page_rule", "A.\n@rule\nB.\n@rule\n", small("rule-thickness = 3pt\nrule-space = 4pt"))
    case("page_widows_orphans_default", "\n".join(para(300 + i, 45) for i in range(6)), SMALL)
    case("page_widows_orphans_strict", "\n".join(para(300 + i, 45) for i in range(6)),
         small("widows = 4\norphans = 3"))
    case("page_widows_orphans_loose", "\n".join(para(300 + i, 45) for i in range(6)),
         small("widows = 1\norphans = 1"))
    case("page_widows_impossible", para(306, 70), small("widows = 20\norphans = 20"))
    case("page_keep_with_next_on",
         para(310, 50) + "@h2 Kept heading\n" + para(311, 40) + "@h2 Another\n" + para(312, 40), SMALL)
    case("page_keep_with_next_off",
         para(310, 50) + "@h2 Kept heading\n" + para(311, 40) + "@h2 Another\n" + para(312, 40),
         small("keep-with-next = off"))
    case("page_keep_chain_headings",
         para(313, 45) + "@h1 One\n@h2 Two\n@vspace height=2pt\n@h3 Three\n" + para(314, 30), SMALL)
    case("page_overfull_unbreakable_heading",
         "Intro.\n@h1 " + prose(315, 40) + "\nAfter.\n",
         small("tolerance = 10000\nh1-size = 10pt\nh1-leading = 14pt\nheading-align = justify"))
    case("page_page_start", "\n".join(para(316 + i, 60) for i in range(3)),
         small("page-start = 2998\nfooter-right = {page}/{pages}"))
    case("page_tall_table_row", "@table cols=2\n" + prose(317, 120) + " | x\n@end\nAfter.\n", SMALL)
    case("page_forcebreak_in_list", "@ul\n@li a\n@newpage\n@li b\n@end\n", SMALL)
    case("page_marker_with_first_line",
         para(318, 52) + "@ol\n@li " + prose(319, 50) + "\n@end\n", SMALL)
    case("page_glue_at_page_top", para(320, 55) + "\n" + para(321, 30) + "@h1 Spaced\n" + para(322, 30),
         small("par-space = 5pt"))
    case("page_rule_and_vspace_heavy",
         "".join("Line %d.\n@rule\n@vspace height=%dpt\n" % (i, 3 + i % 4) for i in range(20)), SMALL)


def g_headers():
    pcase("hdr_all_slots",
          "@doc\ntitle = The Title\nauthor = A. Author\ndate = 2026-10-10\n@end\n"
          "@h1 Chapter one\n@h2 Section a\n" + para(400, 60) + "@h2 Section b\n" + para(401, 60)
          + "@h1* Unnumbered chapter\n" + para(402, 60),
          small("header-baseline = 10pt\nfooter-baseline = 112pt\n"
                "header-left = {title}\nheader-center = {chapter}\nheader-right = {section}\n"
                "footer-left = {author}\nfooter-center = {page}/{pages}\nfooter-right = {date}"))
    case("hdr_even_variants",
         "@h1 First\n" + para(403, 120) + "@h1 Second\n" + para(404, 80),
         small("header-baseline = 10pt\nfooter-baseline = 112pt\nheader-left = odd {page}\n"
               "header-right-even = even {page}\nheader-left-even =\nfooter-center = {chapter}\n"
               "footer-center-even = {section} [{pages}]"))
    case("hdr_escapes_and_literals",
         "@doc\ntitle = {z|x} \\q literal\n@end\nBody.\n",
         small("header-baseline = 10pt\nheader-left = \\{page\\} = {page} \\\\ {title}\n"
               "header-right = #1. Done. J. X"))
    case("hdr_number_off_chapter", "@h1 Plain\n@h2 Sub\nText.\n",
         small("heading-number = off\nheader-baseline = 10pt\nheader-left = {chapter}|{section}"))
    case("hdr_chapter_changes_midpage",
         "@h1 Alpha\nShort.\n@h1 Beta\n" + para(405, 100) + "@h1 Gamma\nShort.\n",
         small("header-baseline = 10pt\nheader-center = [{chapter}] [{section}]"))
    case("hdr_font_size", "@h1 Héading\nX.\n",
         small("header-font = serif\nheader-size = 12pt\nheader-baseline = 8pt\nheader-right = {chapter}\n"
               "footer-left = {page}"))
    case("hdr_front_pages_roman",
         "@toc\n" + "".join("@h1 Heading %d\nText.\n" % i for i in range(1, 15)),
         small("footer-center = {page}\nfooter-center-even = even {page}\nheader-left = {chapter}x"))
    case("hdr_wide_text_offpage", "X.\n",
         small("header-baseline = 10pt\nheader-center = " + "very wide header text " * 5))
    case("hdr_spaces_collapse", "X.\n", small("header-baseline = 10pt\nheader-left = a    b\\\\ c  .  d. E"))


def g_toc():
    case("toc_depth_zero", "@toc\n@h1 A\n@h2 B\n", small("toc-depth = 0"))
    case("toc_depth_four", "@toc\n@h1 A\n@h2 B\n@h3 C\n@h4 D\n@h4* E\n@h3 F\n", TALL,
         )
    case("toc_title_attr_literal", '@toc title="My {b|Contents} \\q"\n@h1 One\n', SMALL)
    case("toc_title_setting_and_fonts", "@toc\n@h1 One\n@h2 Two\n",
         small("toc-title = Inhalt\ntoc-title-font = serif\ntoc-title-size = 14pt\n"
               "toc-title-space-after = 2pt\ntoc-font = sans\ntoc-size = 9pt\ntoc-leading = 11pt\n"
               "heading-italic = on"))
    case("toc_leader_multi", "@toc\n@h1 One\n@h2 Two\n", small("toc-leader = ._\ntoc-leader-gap = 0\n"
                                                              "toc-number-gap = 1pt\ntoc-indent = 30pt"))
    case("toc_many_pages", "@toc\n" + "".join("@h%d Heading %d %s\nText.\n" % (1 + i % 3, i, prose(500 + i, 2))
                                              for i in range(40)), SMALL)
    case("toc_long_entries_wrap", "@toc\n@h1 " + prose(501, 25) + "\n@h2 " + prose(502, 18) + "\n", SMALL)
    case("toc_unnumbered_and_number_off", "@toc\n@h1 One\n@h1* Star\n@h2 Two\n",
         small("heading-number = off"))
    case("toc_empty_entries", "@toc\n@h1\n@h2\nText.\n", SMALL)
    case("toc_empty_entry_number_off", "@toc\n@h1\nText.\n", small("heading-number = off"))
    case("toc_entry_space_reserve", "@toc\n@h1 One\n@h1 Two\n@h1 Three\n",
         small("toc-entry-space = 5pt\ntoc-reserve = 50pt"))
    case("toc_page_start_labels", "@toc\n@h1 One\n" + para(503, 150) + "@h1 Two\nX.\n",
         small("page-start = 98"))
    case("toc_styled_heading_plain_text",
         "@toc\n@h1 {b|Bold} {i|it}~nbsp\\ esc \\{x\\} dis\\-cret {m|mono}  spaced\n", SMALL)
    case("toc_with_doc_and_title_override", "@doc\ntitle = Book\n@end\n@toc title=Index\n@h1 One\n", SMALL)
    case("toc_entries_hyphenate", "@toc\n@h1 Internationalization typesetting conversation "
         "representative accommodation\n",
         med("tolerance = 10000\nheading-align = justify\nh1-size = 16pt"))
    case("toc_hyphenate_off", "@toc\n@h1 Internationalization typesetting conversation "
         "representative accommodation\n",
         med("tolerance = 10000\nheading-align = justify\nh1-size = 16pt\nhyphenate = off"))


# ---------------------------------------------------------------------------
# generated documents
# ---------------------------------------------------------------------------

class DocGen:
    """Builds a random valid Codexa document from a seed.

    `size` scales the number of top-level blocks; `features` restricts which
    block kinds may appear so that a family of cases can focus on one area.
    """

    ALL = ("para", "heading", "list", "quote", "block", "table", "pre", "fig",
           "rule", "vspace", "newpage")

    def __init__(self, seed, size, features=ALL, footnotes=True, unicode=True,
                 fig_max=40):
        self.rng = random.Random(seed)
        self.size = size
        self.features = features
        self.footnotes = footnotes
        self.unicode = unicode
        self.fig_max = fig_max

    def word(self):
        r = self.rng.random()
        if self.unicode and r < 0.03:
            return self.rng.choice(UNICODE_WORDS)
        if r < 0.05:
            return str(self.rng.randint(0, 99999))
        w = self.rng.choice(WORDS)
        if self.rng.random() < 0.08:
            w = w.capitalize()
        return w

    def inline(self, nwords, footnotes, depth=0, styles=True):
        """Random inline text; `styles=False` leaves out the style tags,
        which a table cell cannot contain."""
        rng = self.rng
        parts = []
        i = 0
        while i < nwords:
            r = rng.random()
            if styles and depth < 3 and r < 0.10 and nwords - i > 2:
                n = rng.randint(1, min(5, nwords - i))
                tag = rng.choice("bbiim+-")
                parts.append("{%s|%s}" % (tag, self.inline(n, False, depth + 1)))
                i += n
                continue
            w = self.word()
            r2 = rng.random()
            if r2 < 0.02:
                w = w + "~" + self.word()
            elif r2 < 0.03:
                w = w + "\\ " + self.word()
            elif r2 < 0.045 and len(w) > 4:
                k = rng.randint(2, len(w) - 2)
                w = w[:k] + "\\-" + w[k:]
            elif r2 < 0.055:
                w = rng.choice(["\\{", "\\}", "\\|", "\\\\", "\\@", "\\~"]) + w
            elif r2 < 0.065:
                w = w + "-" + self.word()
            if rng.random() < 0.12:
                w += rng.choice([".", ".", ",", ";", "!", "?", ".)", ".\"", ":"])
            if footnotes and self.footnotes and rng.random() < 0.025:
                w += "{n|%s}" % self.inline(rng.randint(2, 30), False, 1)
            parts.append(w)
            i += 1
        sep = []
        for p in parts:
            sep.append(p)
            sep.append(" " if rng.random() < 0.95 else "  ")
        return "".join(sep[:-1])

    def lines(self, text):
        return wrap(text, self.rng.randint(40, 90))

    def block(self, depth, out, list_ok=True):
        rng = self.rng
        kinds = [k for k in self.features if not (depth > 2 and k in ("list", "quote", "block"))]
        weights = {"para": 10, "heading": 2, "list": 2, "quote": 1, "block": 1, "table": 1,
                   "pre": 1, "fig": 1, "rule": 0.5, "vspace": 0.5, "newpage": 0.3}
        kind = rng.choices(kinds, [weights[k] for k in kinds])[0]
        if kind == "para":
            out.append(self.lines(self.inline(rng.randint(3, 90), True)))
            if rng.random() < 0.5:
                out.append("\n")
        elif kind == "heading":
            lvl = rng.randint(1, 4)
            star = "*" if rng.random() < 0.15 else ""
            out.append("@h%d%s %s\n" % (lvl, star, self.inline(rng.randint(0, 8), False)))
        elif kind == "list":
            tag = rng.choice(["@ul", "@ol"])
            if tag == "@ol" and rng.random() < 0.4:
                tag += " start=%d" % rng.choice([1, 3, 9, 25, 26, 27, 49, 99, 1000])
            out.append(tag + "\n")
            for _ in range(rng.randint(1, 5)):
                out.append("@li " + self.lines(self.inline(rng.randint(0, 30), True)))
                if rng.random() < 0.3:
                    self.block(depth + 1, out)
            out.append("@end\n")
        elif kind == "quote":
            out.append("@q\n")
            for _ in range(rng.randint(1, 3)):
                self.block(depth + 1, out)
            out.append("@end\n")
        elif kind == "block":
            attrs = []
            if rng.random() < 0.5:
                attrs.append("align=%s" % rng.choice(["justify", "left", "right", "center"]))
            if rng.random() < 0.4:
                attrs.append("indent=%dpt" % rng.randint(0, 25))
            if rng.random() < 0.3:
                attrs.append("right-indent=%dpt" % rng.randint(0, 25))
            if rng.random() < 0.3:
                attrs.append("font=%s" % rng.choice(["serif", "sans", "mono"]))
            if rng.random() < 0.3:
                attrs.append("size=%dpt" % rng.randint(7, 13))
            if rng.random() < 0.3:
                attrs.append("leading=%dpt" % rng.randint(9, 16))
            out.append("@block%s\n" % "".join(" " + a for a in attrs))
            for _ in range(rng.randint(1, 3)):
                self.block(depth + 1, out)
            out.append("@end\n")
        elif kind == "table":
            cols = rng.randint(1, 5)
            align = "".join(rng.choice("lrc") for _ in range(cols))
            out.append("@table cols=%d%s\n" % (cols, " align=" + align if rng.random() < 0.7 else ""))
            for _ in range(rng.randint(0, 6)):
                if rng.random() < 0.2:
                    out.append("@hrule\n")
                else:
                    cells = [self.inline(rng.choice([0, 1, 1, 2, 3, 6]), False, styles=False)
                             for _ in range(cols)]
                    out.append(" | ".join(cells) + "\n")
            out.append("@end\n")
        elif kind == "pre":
            out.append("@pre\n")
            for _ in range(rng.randint(0, 8)):
                if rng.random() < 0.15:
                    out.append("\n")
                else:
                    out.append(" " * rng.randint(0, 6) + " ".join(self.word() for _ in range(rng.randint(1, 6)))
                               + " " * rng.randint(0, 2) + "\n")
            out.append("@end\n")
        elif kind == "fig":
            # Small pages get wide figures with short captions so that every
            # figure block fits on one page (guarantee 7 of the spec).
            small_page = self.fig_max <= 20
            w = "" if rng.random() < 0.6 else " width=%dpt" % rng.randint(100 if small_page else 40, 150)
            out.append("@fig height=%dpt%s\n" % (rng.randint(0, self.fig_max), w))
            out.append(self.lines(self.inline(rng.randint(0, 8 if small_page else 15), False)))
            out.append("@end\n")
        elif kind == "rule":
            out.append("@rule\n")
        elif kind == "vspace":
            out.append("@vspace height=%dpt\n" % rng.randint(0, 20))
        elif kind == "newpage":
            out.append("@newpage\n")

    def document(self, doc_meta=None, toc=None):
        out = []
        if doc_meta:
            out.append("@doc\n")
            for k, v in doc_meta:
                out.append("%s = %s\n" % (k, v))
            out.append("@end\n")
        if toc is not None:
            out.append("@toc%s\n" % toc)
        for _ in range(self.size):
            self.block(0, out)
        return "".join(out)


def random_settings(rng, page="small"):
    """A settings file with randomised but guarantee-respecting values."""
    lines = []
    if page == "small":
        lines.append(SMALL.rstrip("\n"))
    elif page == "med":
        lines.append(MED.rstrip("\n"))
    elif page == "a5":
        lines.append("page-width = 148mm\npage-height = 210mm\nmargin-left = 15mm\nmargin-right = 15mm\n"
                     "margin-top = 20mm\nmargin-bottom = 20mm")
    options = [
        "align = %s" % rng.choice(["justify", "left", "right", "center"]),
        "body-font = %s" % rng.choice(["serif", "sans", "mono"]),
        "body-size = %s" % rng.choice(["9pt", "10pt", "11pt", "9.5pt"]),
        "leading = %s" % rng.choice(["11pt", "12pt", "13pt", "14pt"]),
        "tolerance = %d" % rng.choice([100, 200, 500, 2000, 5000]),
        "hyphen-patterns = minimal",
        "hyphenate = off",
        "par-indent = %dpt" % rng.randint(0, 30),
        "par-space = %dpt" % rng.randint(0, 6),
        "heading-align = %s" % rng.choice(["left", "right", "center", "justify"]),
        "heading-number = off",
        "h1-newpage = on",
        "keep-with-next = off",
        "widows = %d" % rng.randint(1, 4),
        "orphans = %d" % rng.randint(1, 4),
        "footnote-min-split = %d" % rng.randint(1, 3),
        "figure-frame = off",
        "figure-caption-align = %s" % rng.choice(["left", "right", "justify"]),
        "list-item-space = %dpt" % rng.randint(0, 4),
        "line-skip = %dpt" % rng.randint(0, 3),
        "ragged-stretch = %d" % rng.randint(1, 6),
        "adj-demerits = %d" % rng.choice([0, 500, 30000]),
        "hyphen-penalty = %d" % rng.choice([-100, 0, 100, 500]),
        "heading-font = %s" % rng.choice(["serif", "sans", "mono"]),
        "toc-depth = %d" % rng.randint(0, 4),
        "header-center = {chapter}",
        "footer-center = {page}",
        "header-right-even = {section}",
        "footer-right = {page} of {pages}",
    ]
    lines.extend(rng.sample(options, rng.randint(0, 8)))
    if any(l.startswith("header") for l in lines):
        lines.append("header-baseline = %dpt" % (10 if page == "small" else 18))
    if any(l.startswith("footer") for l in lines) and page == "small":
        lines.append("footer-baseline = 112pt")
    return "\n".join(lines) + "\n"


def g_generated():
    """Random documents of increasing size on assorted pages and settings."""
    sizes = [3, 5, 8, 10, 12, 16, 20, 24, 28, 32, 40, 50, 65, 80]
    for i, size in enumerate(sizes):
        rng = random.Random(1000 + i)
        page = ["small", "small", "med", "a5", None][i % 5]
        cfg = random_settings(rng, page or "default")
        toc = None if i % 3 else ("" if i % 2 else ' title="Table of contents"')
        meta = [("title", "Generated %d" % i), ("author", "Gen")] if i % 4 == 1 else None
        doc = DocGen(2000 + i, size, fig_max=20 if page == "small" else 60).document(meta, toc)
        case("gen_random_%02d_size_%d" % (i, size), doc, cfg)
    focus = [
        ("paras", ("para",)),
        ("lists", ("para", "list")),
        ("quotes_blocks", ("para", "quote", "block")),
        ("tables", ("para", "table")),
        ("figures", ("para", "fig")),
        ("headings", ("para", "heading")),
        ("pre_rules", ("para", "pre", "rule", "vspace", "newpage")),
    ]
    for j, (label, feats) in enumerate(focus):
        for k in range(2):
            seed = 3000 + j * 10 + k
            rng = random.Random(seed)
            page = ["small", "med", "a5"][k]
            doc = DocGen(seed, 8 + 10 * k, features=feats, fig_max=20 if page == "small" else 60).document(
                toc="" if label == "headings" else None)
            case("gen_focus_%s_%d" % (label, k), doc, random_settings(rng, page))


INJECTIONS = [
    ("{z|", "unknown-inline"), ("}", "stray-brace"), ("\\q", "bad-escape"),
    ("{b|open", "unclosed-inline"),
]


def g_error_injection():
    """Valid random documents with one error injected at a random place."""
    for i in range(8):
        rng = random.Random(5000 + i)
        doc = DocGen(6000 + i, 6 + i, unicode=True).document()
        lines = doc.split("\n")[:-1]
        mode = i % 6
        text_lines = [n for n, l in enumerate(lines) if l and not l.lstrip().startswith("@")]
        if mode == 0 and text_lines:
            n = rng.choice(text_lines)
            frag, _ = INJECTIONS[rng.randrange(len(INJECTIONS))]
            l = lines[n]
            pos = rng.randint(0, len(l))
            lines[n] = l[:pos] + frag + l[pos:]
        elif mode == 1:
            n = rng.randint(0, len(lines))
            lines.insert(n, "@" + rng.choice(["foo", "h5", "list", "li", "hrule", "endd", "toc"]))
        elif mode == 2:
            ends = [n for n, l in enumerate(lines) if l.strip() == "@end"]
            if ends:
                del lines[rng.choice(ends)]
            else:
                lines.append("@end")
        elif mode == 3:
            n = rng.randint(0, len(lines))
            lines.insert(n, rng.choice(["@ol start=0", "@table cols=2 align=lll", "@fig width=1pt",
                                        "@vspace height=3", "@block size=1pt", "@q extra"]))
        elif mode == 4:
            lines.append("@end")
        else:
            n = rng.randint(0, len(lines))
            lines.insert(n, "@table cols=2\na | b | c\n@end")
        cfg = None
        if i % 4 == 3:
            cfg = rng.choice(["align = sideways\n", "tolerance = -1\n", "header-left = {nope}\n",
                              "page-width = 10pt\n", "margin-top = 1pt\nmargin-top = 2pt\n",
                              "body-size = 10pt\nwidows = 0\n"])
        case("errgen_injected_%02d" % i, "\n".join(lines) + "\n", cfg, free=True)


# ---------------------------------------------------------------------------
# large documents
# ---------------------------------------------------------------------------

def book(seed, chapters=6):
    """A long structured document: TOC, four heading levels, nested lists,
    8 tables, 9 figures and 41 footnotes, spread over the chapters."""
    rng = random.Random(seed)
    gen = DocGen(seed + 1, 0, footnotes=False)
    notes = [41 * k // (chapters * 4) for k in range(chapters * 4 + 1)]
    tables = set(rng.sample(range(chapters * 4), 8))
    figures = set(rng.sample(range(chapters * 4), 9))
    out = ["@doc\ntitle = A Generated Book\nauthor = The Test Author\ndate = 10 October 2026\n@end\n",
           "@toc\n"]
    slot = 0
    fn_total = 0
    for c in range(chapters):
        out.append("@h1 %s\n" % prose(seed * 7 + c, rng.randint(2, 5))[:-1])
        for s in range(4):
            out.append("@h%d %s\n" % (2 + (s % 3 == 2), prose(seed * 11 + c * 4 + s, rng.randint(2, 6))[:-1]))
            if s == 3:
                out.append("@h4 %s\n" % prose(seed * 13 + c, 3)[:-1])
            nfn = notes[slot + 1] - notes[slot]
            for p in range(rng.randint(3, 6)):
                text = gen.inline(rng.randint(40, 160), False)
                if nfn and p % 2 == 0:
                    text += "{n|%s}" % gen.inline(rng.randint(5, 50), False)
                    nfn -= 1
                    fn_total += 1
                out.append(wrap(text) + "\n")
            while nfn:
                out.append(wrap(gen.inline(30, False) + "{n|%s}" % gen.inline(12, False)) + "\n")
                nfn -= 1
                fn_total += 1
            if slot in tables:
                cols = rng.randint(2, 6)
                out.append("@table cols=%d align=%s\n" % (cols, "".join(rng.choice("lrc") for _ in range(cols))))
                out.append(" | ".join(gen.word() for _ in range(cols)) + "\n@hrule\n")
                for _ in range(rng.randint(3, 10)):
                    out.append(" | ".join(gen.inline(rng.randint(1, 5), False, styles=False)
                                          for _ in range(cols)) + "\n")
                out.append("@end\n")
            if slot in figures:
                out.append("@fig height=%dpt\n%s\n@end\n" % (rng.randint(60, 200), gen.inline(rng.randint(4, 20), False)))
            if s == 1:
                out.append("@ul\n")
                for _ in range(rng.randint(2, 4)):
                    out.append("@li %s\n" % gen.inline(rng.randint(5, 30), False))
                    if rng.random() < 0.6:
                        out.append("@ol start=%d\n" % rng.randint(1, 30))
                        for _ in range(rng.randint(1, 4)):
                            out.append("@li %s\n" % gen.inline(rng.randint(3, 20), False))
                            if rng.random() < 0.4:
                                out.append("@ul\n@li %s\n@li %s\n@end\n" % (gen.inline(6, False), gen.inline(9, False)))
                        out.append("@end\n")
                out.append("@end\n")
            if s == 2:
                out.append("@q\n%s\n@end\n" % wrap(gen.inline(60, False)))
                out.append("@pre\n%s@end\n" % "".join("    %s\n" % gen.inline(4, False).replace("\\", "/")
                                                       for _ in range(rng.randint(3, 8))))
            slot += 1
    assert fn_total == 41, fn_total
    return "".join(out)


BOOK_CFG = """page-width = 6in
page-height = 9in
margin-left = 0.75in
margin-right = 0.75in
margin-top = 0.8in
margin-bottom = 0.8in
header-baseline = 0.5in
footer-baseline = 8.6in
header-left-even = {title}
header-right = {chapter}
header-left =
footer-center = {page}
h1-newpage = on
"""


def g_big():
    case("big_book", book(7001), BOOK_CFG)
    case("big_book_ragged", book(7002), BOOK_CFG + "align = left\nhyphen-patterns = minimal\nwidows = 3\n")
    case("big_long_paragraph", para(7100, 1800), "")
    case("big_long_paragraph_narrow", para(7101, 1800), med("tolerance = 400"))
    case("big_pre_600_lines",
         "Listing:\n@pre\n" + "".join("%4d  %s\n" % (i, prose(7200 + i % 50, 6)) for i in range(1, 601))
         + "@end\nEnd.\n", "")
    case("big_tolerance_zero_wide", "\n".join(para(7300 + i, 150 + 30 * i) for i in range(6)),
         "tolerance = 0\nmargin-left = 50pt\nmargin-right = 50pt\n")
    case("big_many_footnotes_small_page",
         "".join(para(7400 + i, 30).rstrip("\n") + "{n|" + prose(7500 + i, 10 + (i * 13) % 50) + "}\n\n"
                 for i in range(60)), SMALL)
    case("big_random_long", DocGen(7600, 150, fig_max=60).document(
        [("title", "Long random")], ""), random_settings(random.Random(7601), "a5"))
    case("big_mixed_small_page", DocGen(7700, 120, fig_max=20).document(None, ""),
         SMALL + "header-baseline = 10pt\nfooter-baseline = 112pt\nheader-center = {chapter}\n"
         "footer-center = {page}\n")


FUZZ_PAGE = ("margin-top = 15pt\nmargin-bottom = 15pt\nmargin-left = 15pt\n"
             "margin-right = 15pt\n")


def fuzz_cfg(width, height, extra):
    """A small fuzz-style page of `width` x `height` points plus extra lines."""
    return "page-width = %dpt\npage-height = %dpt\n%s%s" % (width, height, FUZZ_PAGE, extra)


# Fourteen one-line paragraphs, enough body material to spill onto later pages.
SPILL = "".join("Line %d of the body.\n\n" % i for i in range(14))


def g_precision():
    """Cases that pin down rules whose precise reading a test must decide.

    Each pair has one public and one hidden member. The error cases carry
    the expected `file:line:col: code` derived from SPEC.md; the layout cases
    pin tie-breaks, boundary comparisons and whitespace rules that a slightly
    different reading of the spec changes.
    """
    # settings text values are scanned once, left to right
    cfg = merge(SMALL, "header-left = \\{page}")
    pcase("err_settings_escaped_brace_then_stray", DOC1, cfg,
          error=serr(cfg, cfg.count("\n"), "}", "stray-brace"))
    cfg = merge(SMALL, "header-right = }\\q")
    hcase("err_settings_stray_before_bad_escape", DOC1, cfg,
          error=serr(cfg, cfg.count("\n"), "}", "stray-brace"))
    cfg = merge(SMALL, "footer-left = {pa\\ge}")
    hcase("err_settings_placeholder_holds_backslash", DOC1, cfg,
          error=serr(cfg, cfg.count("\n"), "{", "unknown-placeholder"))

    pcase("hdr_escaped_braces_literal", "@h1 Alpha\nText.\n",
          small("header-left = \\{{chapter}\\}\nfooter-right = a\\}b \\\\ {page}"))

    # a figure caption is scanned at its @end
    doc = "@fig height=1pt\n{z|bad}\n@rule\n@end\n"
    pcase("err_fig_caption_scanned_at_end", doc, SMALL,
          error=derr(doc, 3, "@", "block-not-allowed"))
    hcase("err_fig_caption_missing_end_first", "@fig height=1pt\nok\n{z|bad}\n", SMALL,
          error="document.cdx:4:1: missing-end")

    # placement sits between the attribute name passes and the value passes
    doc = "@table cols=1\na\n@vspace height=abc\n@end\n"
    pcase("err_placement_before_value_check", doc, SMALL,
          error=derr(doc, 3, "@", "block-not-allowed"))
    doc = "@table cols=1\na\n  @vspace\n@end\n"
    hcase("err_missing_attribute_before_placement", doc, SMALL,
          error=derr(doc, 3, "@", "missing-attribute"))
    doc = "Para.\n\n@end now=1\n"
    hcase("err_end_attribute_before_unexpected", doc, SMALL,
          error=derr(doc, 3, "now", "bad-attribute"))

    doc = "@table cols=1\na\n@vspace foo=1\n@end\n"
    pcase("err_attribute_name_before_placement", doc, SMALL,
          error=derr(doc, 3, "foo", "bad-attribute"))

    # a second, misplaced @toc
    doc = "@toc\n@q\n  @toc\n@end\n"
    pcase("err_second_toc_in_quote", doc, SMALL, error=derr(doc, 3, "@", "duplicate-toc"))
    doc = "@toc\n@ul\n@toc\n@li a\n@end\n"
    hcase("err_second_toc_in_list_head", doc, SMALL,
          error=derr(doc, 3, "@", "block-not-allowed"))

    # positions that the error table alone does not give
    doc = "@ol\n    stray words\n@li a\n@end\n"
    pcase("err_text_not_allowed_indented", doc, SMALL,
          error=derr(doc, 2, "s", "text-not-allowed"))
    hcase("err_empty_value_at_end_of_line", "A.\n@vspace height=\n", SMALL,
          error="document.cdx:2:16: bad-attribute-value")
    doc = '@fig height=""\nx\n@end\n'
    hcase("err_quoted_empty_length", doc, SMALL, error=derr(doc, 1, '"', "bad-attribute-value"))

    # a backslash at the end of a non-final source line escapes the join
    pcase("inl_backslash_escapes_line_join",
          "First word\\\nsecond word and more.\n\nThird\\\n\\\nfourth.\n"
          "@fig height=5pt\nCap\\\ntion.\n@end\n", SMALL)
    hcase("inl_backslash_escapes_join_item_caption",
          "@ul\n@li item text\\\ncontinues here\n@end\n@fig height=5pt\nCap\\\ntion text.\n@end\n"
          "Body\\\n  indented.\n", SMALL)

    # discretionary points at the edges of a fragment: one at the end of a
    # word is discarded and leaves Liang hyphenation in force
    disc_page = ("margin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\n"
                 "margin-right = 20pt\npage-height = 300pt\npar-indent = 0\nalign = left\n")
    pcase("hyph_disc_at_fragment_edges",
          "is and typesetting\\- paragraph\\- a of and is paragraph\\- of the to "
          "hyphenation\\- a introduction\\- paragraph\\- introduction\\- is national\\- "
          "to is paragraph\\- {b|type}\\-setting \\-national\n",
          disc_page + "page-width = 120pt\n")
    hcase("hyph_disc_at_fragment_edges_narrow",
          "to is is national\\- paragraph\\- national\\- of is of of in and is "
          "hyphenation\\- (typesetting\\-)\n",
          disc_page + "page-width = 100pt\n")

    # leading and trailing glue of a header slot is removed
    hdoc = "@h1 Alpha\nText.\n@newpage\n@h2 Beta\nMore.\n@newpage\nLast.\n"
    pcase("hdr_empty_placeholder_at_edges", hdoc,
          small("header-center = {section} - {page}\nheader-right = {chapter} {section}\n"
                "footer-left = {section}  {page}"))
    hcase("hdr_empty_placeholder_at_edges_even", hdoc,
          small("header-right-even = {page} {section}\nfooter-center = {title} {page} {author}\n"
                "footer-right-even = {section}"))

    # float-min-body is a >= comparison: these zones leave exactly that much
    pcase("fig_min_body_exact", "@fig height=31414\nX.\n@end\n" + SPILL, SMALL)
    hcase("fig_min_body_exact_two",
          "@fig height=10pt\nOne.\n@end\n@fig height=10828\nTwo.\n@end\n" + SPILL,
          small("float-min-body = 10pt"))

    # a body of only a FLOATMARK is not an empty body for the forced footnote line
    note = " ".join(["footnote words keep going around the measure"] * 14)
    pcase("fn_floatmark_only_body",
          "Text{n|" + note + "} here.\n@fig height=60pt\nCap.\n@end\n@newpage\n"
          "@fig height=10pt\nSecond.\n@end\n",
          small("float-min-body = 0\nfloat-space-after = 0"))
    hcase("fn_floatmark_only_body_two_notes",
          "One{n|" + note + "} and two{n|" + note[:120] + "}.\n@fig height=58pt\nCap.\n@end\n"
          "@newpage\n@fig height=12pt\nSecond.\n@end\n",
          small("float-min-body = 0\nfloat-space-after = 0\nfootnote-item-space = 3pt"))

    # line-breaking ties: final class, node creation order, predecessor number
    pcase("brk_tie_final_class", "integer and typesetting ok! jumps an quick so\n",
          fuzz_cfg(180, 110, "hyphen-penalty = 0\nline-penalty = 0\n"))
    hcase("brk_tie_final_class_b", "so Introduction by a typesetting if it penalty at\n",
          fuzz_cfg(150, 120, "hyphen-penalty = 0\nadj-demerits = 0\nline-penalty = 0\n"
                   "final-hyphen-demerits = 0\n"))
    pcase("brk_tie_node_order",
          "end. brown justification ok! in Smith is and to and etc. (note) end. measure "
          "column Smith an heading of at glue y justification we or brown so x over\n\n"
          "justification\n\nin at up mm justification and y penalty over so and\n",
          fuzz_cfg(180, 120, "align = right\npar-indent = 0\nhyphen-penalty = 100\n"
                   "adj-demerits = 0\n"))
    hcase("brk_tie_node_order_b",
          "the heading if etc. translate of\n\na a on so national J. measure winter national "
          "etc. in island mm J. or discretionary algorithm or mm y etc. glue heading Smith "
          "\"quoted.\" if on to glue measure national in dog integer as\n",
          fuzz_cfg(180, 200, "align = left\ntolerance = 500\npar-indent = 0\n"))
    pcase("brk_tie_predecessor", "mm nested paragraph (note) typesetting y\n",
          fuzz_cfg(180, 120, "align = left\ntolerance = 500\npar-indent = 0\nline-penalty = 1\n"))
    hcase("brk_tie_predecessor_b", "end. column we hyphenation hyphenation is end. x\n",
          fuzz_cfg(150, 120, "hyphen-penalty = -100\nadj-demerits = 500000\n"))

    # roman list markers keep the greedy rule above 3999
    pcase("list_ol_roman_over_3999",
          "@ol\n@li a\n@ol\n@li b\n@ol start=3998\n@li x\n@li y\n@li z\n@end\n@end\n@end\n",
          SMALL, wantsub=['"mmmcmxcviii."', '"mmmm."'])
    hcase("list_ol_roman_far_over_3999",
          "@ul\n@li a\n@ul\n@li b\n@ol start=5001\n@li x\n@li y\n@end\n@end\n@end\n",
          small("page-width = 400pt"), wantsub=['"mmmmmi."', '"mmmmmii."'])


def register_all():
    g_examples()
    g_settings()
    g_config()
    g_errors()
    g_inline()
    g_hyphen()
    g_breaking()
    g_align()
    g_headings()
    g_lists()
    g_quotes()
    g_groups()
    g_pre()
    g_tables()
    g_footnotes()
    g_figures()
    g_pages()
    g_headers()
    g_toc()
    g_generated()
    g_error_injection()
    g_big()
    g_precision()


if __name__ == "__main__":
    sys.exit(main())
