"""Command-line interface: read a problem on stdin, print the resolution."""

from __future__ import annotations

import argparse
import sys
from typing import Sequence

from . import __version__
from .parser import parse_problem
from .resolver import resolve


def format_result(text: str) -> str:
    """Resolve the problem in *text* and return the exact output text."""
    registry, root = parse_problem(text)
    resolution = resolve(registry, root)
    if resolution is None:
        return "unsatisfiable\n"
    return "".join(line + "\n" for line in resolution.lines())


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="depresolve",
        description="Resolve package dependencies read from standard input "
        "(registry lines followed by a 'root:' line) and print one "
        "'name version' line per chosen package, or 'unsatisfiable'.",
    )
    parser.add_argument("--version", action="version", version=__version__)
    parser.parse_args(argv)
    text = sys.stdin.buffer.read().decode("ascii")
    sys.stdout.write(format_result(text))
    sys.stdout.flush()
    return 0
