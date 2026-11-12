"""Command-line interface: perft / divide queries on stdin, results on stdout.

Each input line is a FEN record (six fields) followed by either ``<depth>``
(print one count) or ``divide <depth>`` (print per-move counts and a total).
"""

from __future__ import annotations

import sys
from typing import Iterable, Iterator

from .perft import divide, perft
from .position import FenError, Position


def run_query(line: str) -> Iterator[str]:
    """Answer one query line, yielding the output lines."""
    fields = line.split()
    if len(fields) == 7:
        depth = int(fields[6])
        yield str(perft(Position.from_fen(" ".join(fields[:6])), depth))
    elif len(fields) == 8 and fields[6] == "divide":
        total = 0
        for move, count in divide(Position.from_fen(" ".join(fields[:6])), int(fields[7])):
            total += count
            yield f"{move} {count}"
        yield f"total {total}"
    else:
        raise ValueError(f"malformed query: {line!r}")


def process(lines: Iterable[str]) -> Iterator[str]:
    """Answer every non-blank query in ``lines``, yielding output lines."""
    for line in lines:
        if line.strip():
            yield from run_query(line)


def main(argv: list[str] | None = None) -> int:
    """Entry point; reads stdin, writes stdout, returns the exit status."""
    args = sys.argv[1:] if argv is None else argv
    if args:
        print("usage: chess-perft  (queries on stdin, results on stdout)", file=sys.stderr)
        return 2
    out = sys.stdout
    try:
        for text in process(sys.stdin):
            out.write(text + "\n")
            out.flush()
    except (ValueError, FenError) as exc:
        print(f"chess-perft: {exc}", file=sys.stderr)
        return 1
    return 0
