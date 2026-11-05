#!/usr/bin/env python3
"""Code and test size of each implementation, and the share of its code that is tests, per language.

    tools/code_stats.py DIR [--langs d,go]

DIR holds <rep>/<lang>/<slug> projects (e.g. implementations). Lines are non-blank lines of the language's
source files, outside build outputs. Test lines are those in the language's test files (Go *_test.go, Python
test_*.py or tests/, Rust tests/ and #[cfg(test)] modules, D and C++ files under a test directory or named
*test*); the rest are code.
"""
import argparse
import collections
import glob
import os
import re
import sys

EXT = {"cpp": (".cpp", ".cc", ".cxx", ".hpp", ".h", ".hh"), "rust": (".rs",), "go": (".go",), "d": (".d",),
       "python": (".py",)}
NAMES = {"cpp": "C++", "rust": "Rust", "go": "Go", "d": "D", "python": "Python"}
BUILD = re.compile(r"(^|/)(target|build|\.dub|bin|obj|\.cache|__pycache__|cmake-build[^/]*|CMakeFiles)/")


def is_test(lang, rel):
    parts = rel.split("/")
    name = parts[-1]
    in_test_dir = any(p in ("test", "tests", "testing", "unittest", "unittests") for p in parts[:-1])
    if lang == "go":
        return name.endswith("_test.go")
    if lang == "python":
        return in_test_dir or name.startswith("test_") or name.endswith("_test.py")
    return in_test_dir or "test" in name.lower()


def project_lines(project, lang):
    counts = {"code": 0, "test": 0}
    for path in glob.glob(os.path.join(project, "**", "*"), recursive=True):
        rel = os.path.relpath(path, project)
        if not os.path.isfile(path) or not path.endswith(EXT[lang]) or BUILD.search(rel):
            continue
        lines = [l for l in open(path, errors="replace").read().splitlines() if l.strip()]
        if is_test(lang, rel):
            counts["test"] += len(lines)
            continue
        if lang == "rust":
            # An inline #[cfg(test)] module, from the attribute to the end of the file, is test code.
            for i, l in enumerate(lines):
                if l.strip() == "#[cfg(test)]":
                    counts["test"] += len(lines) - i
                    lines = lines[:i]
                    break
        counts["code"] += len(lines)
    return counts


def collect(root, langs=None):
    """{lang: [(slug, rep, code, test)]} for the projects under root."""
    out = collections.defaultdict(list)
    for project in sorted(glob.glob(os.path.join(root, "rep*", "*", "*"))):
        rep, lang, slug = project.split(os.sep)[-3:]
        if lang in EXT and (not langs or lang in langs):
            c = project_lines(project, lang)
            out[lang].append((slug, rep, c["code"], c["test"]))
    return out


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return (xs[n // 2] + xs[(n - 1) // 2]) / 2 if xs else 0


def report(data):
    out = ["| Language | Projects | Code lines (median) | Test lines (median) | Test share (median) |",
           "|---|---:|---:|---:|---:|"]
    for lang in sorted(data, key=lambda l: list(NAMES).index(l)):
        rows = data[lang]
        share = [t / (c + t) for _, _, c, t in rows if c + t]
        out.append(f"| {NAMES[lang]} | {len(rows)} | {median([c for _, _, c, _ in rows]):.0f} | "
                   f"{median([t for _, _, _, t in rows]):.0f} | {100 * median(share):.0f}% |")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("--langs", default="")
    a = ap.parse_args()
    data = collect(a.dir, set(a.langs.split(",")) if a.langs else None)
    if not data:
        sys.exit(f"no implementations under {a.dir}")
    print(report(data))


if __name__ == "__main__":
    main()
