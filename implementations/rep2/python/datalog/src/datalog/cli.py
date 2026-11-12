"""Command-line interface: read a program on stdin, print the query answers."""

from __future__ import annotations

import gc
import sys

from .errors import DatalogError
from .solve import solve


def main(argv: list[str] | None = None) -> int:
    """Run the tool.  Prints ``error`` (and exits 0) for a program that is
    malformed, unsafe or not stratifiable; the reason goes to stderr."""
    # The engine allocates millions of small tuples and no reference cycles;
    # the cyclic collector would only burn time rescanning them.
    gc.disable()
    source = sys.stdin.buffer.read().decode("ascii", errors="replace")
    try:
        output = solve(source)
    except DatalogError as exc:
        print(f"datalog: {exc}", file=sys.stderr)
        output = "error\n"
    sys.stdout.write(output)
    sys.stdout.flush()
    return 0
