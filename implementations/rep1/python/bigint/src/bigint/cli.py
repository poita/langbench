"""Command-line interface: read queries on stdin, write results on stdout."""

from __future__ import annotations

import sys

from .queries import evaluate_queries


def main(argv: list[str] | None = None) -> int:
    """Run the CLI. Input is one ``<a> <op> <b>`` query per line (UTF-8)."""
    argv = sys.argv[1:] if argv is None else argv
    if argv:
        print("usage: python -m bigint < queries.txt", file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    out = list(evaluate_queries(lines))
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    sys.stdout.flush()
    return 0
