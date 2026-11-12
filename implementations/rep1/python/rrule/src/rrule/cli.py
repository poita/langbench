"""Command-line interface.

Reads one ``<DTSTART> <RRULE> <N>`` rule per line on stdin and writes, for
each, the first ``N`` occurrences as space-separated ``YYYYMMDDTHHMMSS``.
"""

from __future__ import annotations

import sys
from collections.abc import Iterable
from itertools import islice

from .expand import occurrences
from .rule import parse_line


def process_line(line: str) -> str:
    """Return the output line (without newline) for one input line."""
    dtstart, rule, limit = parse_line(line)
    return " ".join(
        [
            "%04d%02d%02dT%02d%02d%02d" % occ
            for occ in islice(occurrences(dtstart, rule, limit), limit)
        ]
    )


def run(lines: Iterable[str], out) -> None:
    """Process input *lines* (with or without line endings), writing to *out*."""
    for line in lines:
        line = line.rstrip("\r\n")
        if line:
            out.write(process_line(line))
            out.write("\n")


def main(argv: list[str] | None = None) -> int:
    run(sys.stdin, sys.stdout)
    sys.stdout.flush()
    return 0
