"""Command-line front end: batch pattern/subject matching on stdin/stdout.

Input and output formats are described in the README.
"""

from __future__ import annotations

import sys
from typing import TextIO

from .errors import PatternSyntaxError
from .pattern import Match, compile


def format_match(m: Match | None) -> str:
    """One output line (without newline) for a search result."""
    if m is None:
        return "no"
    parts = [f"match {m.start} {m.end}"]
    for g in m.groups:
        parts.append("-" if g is None else f"{g[0]},{g[1]}")
    return "|".join(parts)


def process(lines: list[str]) -> list[str]:
    """Run a whole input (already split into lines); return the output lines."""
    out: list[str] = []
    idx = 0
    count = int(lines[idx])
    idx += 1
    for _ in range(count):
        pattern = lines[idx]
        subjects = int(lines[idx + 1])
        idx += 2
        search = compile(pattern).search
        for subject in lines[idx:idx + subjects]:
            out.append(format_match(search(subject)))
        idx += subjects
    return out


def main(argv: list[str] | None = None, stdin: TextIO | None = None,
         stdout: TextIO | None = None) -> int:
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    if stdin is sys.stdin:
        data = sys.stdin.buffer.read().decode("utf-8")
    else:
        data = stdin.read()
    lines = data.split("\n")
    try:
        out = process(lines)
    except (PatternSyntaxError, ValueError, IndexError) as exc:
        print(f"btregex: {exc}", file=sys.stderr)
        return 2
    if out:
        stdout.write("\n".join(out))
        stdout.write("\n")
    return 0
