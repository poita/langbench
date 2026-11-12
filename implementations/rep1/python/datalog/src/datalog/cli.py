"""Command-line front end: program on stdin, query answers on stdout."""

from __future__ import annotations

import sys

from .api import run


def main() -> int:
    sys.stdout.write(run(sys.stdin.read()))
    sys.stdout.flush()
    return 0
