"""Command-line interface.

Reads the filter (first line) and one JSON document (the rest) from stdin and
prints each result as a compact JSON line.  If evaluation fails, the results
produced before the failure are printed, then a line ``error``.
"""

from __future__ import annotations

import sys
from typing import BinaryIO, Sequence

from . import Filter, dumps, loads
from .errors import JQError, JQSyntaxError, JSONDecodeError

USAGE = """usage: jqlite < input

Line 1 of stdin is the filter; the remaining text is one JSON document.
Each result is printed as one line of compact JSON.  A runtime error prints
"error" and stops (exit status stays 0)."""


def run_text(filter_text: str, document: str) -> tuple[list[str], bool]:
    """Evaluate and return ``(output lines, errored)``."""
    flt = Filter(filter_text)
    out: list[str] = []
    try:
        for v in flt.run(loads(document)):
            out.append(dumps(v))
    except JQError:
        return out, True
    return out, False


def main(argv: Sequence[str] | None = None, stdin: BinaryIO | None = None,
         stdout: BinaryIO | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        print(USAGE, file=sys.stderr)
        return 0 if args[0] in ("-h", "--help") else 2
    sys.setrecursionlimit(20000)
    data = (stdin or sys.stdin.buffer).read()
    first, _, rest = data.partition(b"\n")
    try:
        lines, errored = run_text(first.decode("utf-8"), rest.decode("utf-8"))
    except (JQSyntaxError, JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"jqlite: {exc}", file=sys.stderr)
        return 2
    if errored:
        lines.append("error")
    text = "\n".join(lines)
    if lines:
        text += "\n"
    (stdout or sys.stdout.buffer).write(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
