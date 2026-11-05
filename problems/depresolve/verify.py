#!/usr/bin/env python3
"""Verifier for the `depresolve` problem.

Usage: verify.py <input.in> <actual.out> [<expected.out>]

The output must be either the single line `unsatisfiable` or a list of
`<name> <version>` lines in strictly increasing name order, one per package.
A resolved set is checked independently of the reference: every listed
package version exists in the registry, every root requirement and every
requirement of every listed package version is met by the listed version of
its target, every listed package is reachable from the root through listed
versions, and nothing else is listed. Because the specified search is
deterministic, the set must also equal the expected output exactly; an
`unsatisfiable` answer is accepted only when the expected output is
`unsatisfiable`. Trailing whitespace on a line and trailing blank lines are
tolerated. Exit 0 on pass; otherwise print a reason and exit 1.
"""
import re
import sys

VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")


def fail(msg):
    print(msg)
    sys.exit(1)


def parse_version(s):
    m = VERSION_RE.match(s)
    if not m:
        return None
    return tuple(int(x) for x in m.groups())


def parse_range(s):
    """Return a predicate over version tuples for the range text s."""
    if s == "*":
        return lambda v: True
    if s[0] == "^":
        lo = parse_version(s[1:])
        if lo[0] > 0:
            hi = (lo[0] + 1, 0, 0)
        elif lo[1] > 0:
            hi = (0, lo[1] + 1, 0)
        else:
            hi = (0, 0, lo[2] + 1)
        return lambda v: lo <= v < hi
    if s[0] == "~":
        lo = parse_version(s[1:])
        hi = (lo[0], lo[1] + 1, 0)
        return lambda v: lo <= v < hi
    if s[0] in "<>":
        preds = []
        for tok in s.split(" "):
            if tok.startswith(">="):
                w = parse_version(tok[2:])
                preds.append(lambda v, w=w: v >= w)
            elif tok.startswith("<="):
                w = parse_version(tok[2:])
                preds.append(lambda v, w=w: v <= w)
            elif tok.startswith(">"):
                w = parse_version(tok[1:])
                preds.append(lambda v, w=w: v > w)
            else:
                w = parse_version(tok[1:])
                preds.append(lambda v, w=w: v < w)
        return lambda v: all(p(v) for p in preds)
    exact = parse_version(s)
    return lambda v: v == exact


def parse_input(text):
    registry = {}
    root = []
    for line in text.split("\n"):
        if not line:
            continue
        head, _, tail = line.partition(":")
        if tail.startswith(" "):
            tail = tail[1:]
        deps = []
        if tail:
            for item in tail.split(", "):
                name, _, rng = item.partition(" ")
                deps.append((name, rng, parse_range(rng)))
        if head == "root":
            root = deps
        else:
            name, ver = head.split(" ")
            registry.setdefault(name, {})[parse_version(ver)] = deps
    return registry, root


def main():
    in_path, actual_path = sys.argv[1], sys.argv[2]
    expected_path = sys.argv[3] if len(sys.argv) > 3 else None

    with open(in_path, encoding="utf-8") as f:
        registry, root = parse_input(f.read())
    with open(actual_path, encoding="utf-8", errors="replace") as f:
        lines = [l.rstrip() for l in f.read().replace("\r\n", "\n").split("\n")]
    while lines and lines[-1] == "":
        lines.pop()

    expected = None
    if expected_path:
        with open(expected_path, encoding="utf-8") as f:
            expected = [l.rstrip() for l in f.read().split("\n")]
        while expected and expected[-1] == "":
            expected.pop()

    if lines == ["unsatisfiable"]:
        if expected is None:
            fail("cannot accept 'unsatisfiable' without the expected output to compare against")
        if expected != ["unsatisfiable"]:
            fail("claimed unsatisfiable but a solution exists")
        return

    chosen = {}
    prev = None
    for i, line in enumerate(lines):
        parts = line.split(" ")
        if len(parts) != 2:
            fail(f"line {i + 1} must be exactly '<name> <version>'; got {line!r}")
        name, ver = parts
        if not NAME_RE.match(name):
            fail(f"line {i + 1}: {name!r} is not a package name")
        v = parse_version(ver)
        if v is None:
            fail(f"line {i + 1}: {ver!r} is not a MAJOR.MINOR.PATCH version")
        if prev is not None and name <= prev:
            fail(f"line {i + 1}: {name!r} is not in strictly increasing name order after {prev!r}")
        prev = name
        if name not in registry or v not in registry[name]:
            fail(f"line {i + 1}: {name} {ver} is not in the registry")
        chosen[name] = v

    if expected == ["unsatisfiable"]:
        fail("listed a resolution but the instance is unsatisfiable")

    # Every requirement of the root and of every chosen version must be met
    # by the chosen version of its target.
    def check(owner, deps):
        for dep, rng, ok in deps:
            if dep not in chosen:
                fail(f"{owner} requires {dep} {rng} but {dep} is not in the output")
            if not ok(chosen[dep]):
                fail(f"{owner} requires {dep} {rng} but the output has {dep} "
                     f"{'.'.join(map(str, chosen[dep]))}")

    check("root", root)
    for name, v in chosen.items():
        check(f"{name} {'.'.join(map(str, v))}", registry[name][v])

    # Every chosen package must be reachable from the root via chosen versions.
    seen = set()
    stack = [d for d, _, _ in root]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack.extend(d for d, _, _ in registry[n][chosen[n]])
    extra = sorted(set(chosen) - seen)
    if extra:
        fail(f"packages not reachable from the root: {' '.join(extra)}")

    if expected is not None and lines != expected:
        fail("the resolution is valid but is not the one the specified search order produces")


if __name__ == "__main__":
    main()
