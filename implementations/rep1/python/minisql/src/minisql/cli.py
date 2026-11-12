"""Command-line interface: read a SQL script on stdin, print SELECT results."""

from __future__ import annotations

import argparse
import sys
from typing import Sequence

from . import __version__
from .database import Database
from .output import format_results


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="minisql",
        description="Execute a SQL script read from standard input and print "
        "the result of every SELECT. A failing statement prints 'error'.",
    )
    parser.add_argument("--version", action="version", version=f"minisql {__version__}")
    parser.parse_args(argv)

    script = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    output = format_results(Database().execute(script))
    sys.stdout.buffer.write(output.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0
