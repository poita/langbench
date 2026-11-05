#!/usr/bin/env python3
"""Compare languages' runtime performance in one lbench tag, relative to a baseline language.

    tools/compare.py TAG [--metric cycles] [--baseline go] [--langs cpp,rust,go,d,python] [--problems a,b]

TAG is an lbench tag name (looked up in .lbench/tags/) or a tag directory; several, comma-separated, are combined. Every language is compared input by
input with the baseline language's implementation of the same problem; only inputs where both produced correct
output count. Prints, per language, the geometric mean and spread of the ratios and how many problems are slower
than the baseline, then a problem-by-language table. Ratios below 1 mean faster than the baseline.
"""
import argparse
import collections
import csv
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
METRICS = {"cycles": "cycles_min", "instr": "instr_min", "wall": "wall_min", "cpu": "cpu_min", "rss": "rss_mb"}
NAMES = {"cpp": "C++", "rust": "Rust", "go": "Go", "d": "D", "python": "Python"}
ORDER = list(NAMES)


def gmean(xs):
    xs = [x for x in xs if x > 0]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else math.nan


def percentile(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def ratios(rows, column, baseline, with_bounds=False):
    """{lang: {problem: [ratio per input]}} against the baseline language.

    Correct runs count as measured. A timed-out run counts at its timeout, which makes that ratio a lower
    bound; with_bounds also returns the set of (lang, problem, input) lower bounds. Inputs where the
    baseline itself failed or timed out are skipped."""
    by = collections.defaultdict(dict)
    for r in rows:
        if r["status"] in ("ok", "timeout") and float(r[column]) > 0:
            by[(r["slug"], r["input"])][r["lang"]] = (float(r[column]), r["status"])
    out = collections.defaultdict(lambda: collections.defaultdict(list))
    lower = set()
    for (slug, inp), vals in by.items():
        if baseline not in vals or vals[baseline][1] != "ok":
            continue
        for lang, (v, status) in vals.items():
            if lang != baseline:
                out[lang][slug].append(v / vals[baseline][0])
                if status == "timeout":
                    lower.add((lang, slug, inp))
    rat = {lang: dict(p) for lang, p in out.items()}
    return (rat, lower) if with_bounds else rat


def short_inputs(rows, seconds):
    """(problem, input, fastest wall time) for inputs whose fastest correct run took under `seconds`."""
    best = {}
    for r in rows:
        if r["status"] == "ok":
            k = (r["slug"], r["input"])
            best[k] = min(best.get(k, math.inf), float(r["wall_min"]))
    return sorted((s, i, round(t, 3)) for (s, i), t in best.items() if t < seconds)


def summary(rat, lower=frozenset()):
    out = {}
    for lang, per in rat.items():
        inputs = [x for xs in per.values() for x in xs]
        per_problem = [gmean(xs) for xs in per.values()]
        out[lang] = {"gmean": gmean(inputs), "inputs": len(inputs), "problems": len(per),
                     "slower": sum(g > 1 for g in per_problem),
                     "p25": percentile(inputs, 25), "p50": percentile(inputs, 50), "p75": percentile(inputs, 75),
                     "lower_bounds": sum(1 for l, _, _ in lower if l == lang)}
    return out


def tag_rows(tags):
    """Rows of one tag, or of several given as a comma-separated list (e.g. languages run separately)."""
    rows = []
    for tag in tags.split(","):
        d = tag if os.path.isdir(tag) else os.path.join(os.environ.get("LBENCH_DIR", os.path.join(ROOT, ".lbench")),
                                                         "tags", tag)
        path = os.path.join(d, "runs.csv")
        if not os.path.exists(path):
            sys.exit(f"no results for tag {tag} ({path})")
        rows += list(csv.DictReader(open(path)))
    return rows


def report(tag, metric="cycles", baseline="go", langs=None, problems=None, short_seconds=5.0):
    rows = [r for r in tag_rows(tag) if (not langs or r["lang"] in langs | {baseline})
            and (not problems or r["slug"] in problems)]
    rat, lower = ratios(rows, METRICS[metric], baseline, with_bounds=True)
    if not rat:
        return f"no inputs where another language and {NAMES.get(baseline, baseline)} both succeeded"
    s = summary(rat, lower)
    order = sorted(rat, key=lambda l: ORDER.index(l) if l in ORDER else 99)
    b = NAMES.get(baseline, baseline)
    out = [f"{metric} relative to {b} (geometric mean over inputs; below 1 is faster; >= marks a figure that "
           f"includes timed-out runs counted at their timeout, so the true value is higher)", "",
           f"| Language | vs {b} | p25 | median | p75 | Problems | Slower than {b} | Timeouts |",
           "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for lang in order:
        x = s[lang]
        ge = ">=" if x["lower_bounds"] else ""
        out.append(f"| {NAMES.get(lang, lang)} | {ge}{x['gmean']:.2f}x | {x['p25']:.2f} | {x['p50']:.2f} | {x['p75']:.2f} "
                   f"| {x['problems']} | {x['slower']} | {x['lower_bounds']} |")
    slugs = sorted({p for per in rat.values() for p in per})
    out += ["", "| Problem | " + " | ".join(NAMES.get(l, l) for l in order) + " |",
            "|---|" + "---:|" * len(order)]
    for slug in slugs:
        cells = [(">=" if any(l == x and slug == y for x, y, _ in lower) else "") + f"{gmean(rat[l][slug]):.2f}x"
                 if slug in rat[l] else "" for l in order]
        out.append(f"| {slug} | " + " | ".join(cells) + " |")
    short = short_inputs(rows, short_seconds)
    if short:
        out += ["", f"{len(short)} inputs took under {short_seconds:g} s for their fastest language, so start-up "
                f"and timer resolution weigh more there: " + ", ".join(f"{s} {i} ({t:.2f} s)" for s, i, t in short)]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tag")
    ap.add_argument("--metric", default="cycles", choices=list(METRICS))
    ap.add_argument("--baseline", default="go")
    ap.add_argument("--langs", default="")
    ap.add_argument("--problems", default="")
    a = ap.parse_args()
    print(report(a.tag, a.metric, a.baseline, set(a.langs.split(",")) if a.langs else None,
                 set(a.problems.split(",")) if a.problems else None))


if __name__ == "__main__":
    main()
