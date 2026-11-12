"""Command-line interface: read a problem input on stdin, print the result."""

from __future__ import annotations

import sys
from collections.abc import Sequence

from .textio import simulate


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point. Reads all of stdin and writes the 34-line result to stdout."""
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        print("usage: python -m chip8  < input > output", file=sys.stderr)
        return 0 if args in (["-h"], ["--help"]) else 2
    try:
        output = simulate(sys.stdin.read())
    except ValueError as exc:
        print(f"chip8: invalid input: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(output)
    return 0
