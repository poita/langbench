"""Command-line interface.

Reads one operation per line on stdin (``<op> <a> [<b>]``, operands as 8 hex
digits) and writes one 8-digit hex result per line on stdout.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence

from .api import evaluate_line


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        print("usage: softfloat < operations.txt > results.txt", file=sys.stderr)
        return 0 if args in (["-h"], ["--help"]) else 2
    out = []
    for lineno, line in enumerate(sys.stdin.read().splitlines(), 1):
        try:
            out.append(evaluate_line(line))
        except ValueError as exc:
            print(f"softfloat: line {lineno}: {exc}", file=sys.stderr)
            return 1
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
