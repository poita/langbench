"""Command-line interface: one scramble per stdin line -> one solution per line."""

from __future__ import annotations

import sys

from .notation import format_moves, parse_moves
from .solver import default_solver


def split_lines(text: str) -> list[str]:
    """Split input into scramble lines.

    A terminating newline does not start a new line (``"R\\n"`` and ``"R"`` are
    one scramble) but a blank line is an empty scramble (``"R\\n\\n"`` is two).
    """
    lines = text.split("\n")
    if text.endswith("\n"):
        lines.pop()
    return lines


def solve_text(text: str) -> str:
    """Solve every scramble in ``text``; returns the full output text."""
    solver = default_solver()
    cache: dict[str, str] = {}
    out = []
    for line in split_lines(text):
        line = line.strip()
        if line not in cache:
            cache[line] = format_moves(solver.solve_scramble(parse_moves(line)))
        out.append(cache[line])
    return "".join(s + "\n" for s in out)


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv:
        print("usage: python -m rubiks < scrambles.txt > solutions.txt", file=sys.stderr)
        return 0 if argv in (["-h"], ["--help"]) else 2
    try:
        text = sys.stdin.buffer.read().decode("utf-8")
        result = solve_text(text)
    except ValueError as exc:
        print(f"rubiks: error: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(result)
    sys.stdout.flush()
    return 0
