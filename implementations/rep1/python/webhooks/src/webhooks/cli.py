"""Command-line entry point: read commands on stdin, write results on stdout."""

from __future__ import annotations

import sys

from .protocol import run

__all__ = ["main"]


def main() -> int:
    data = sys.stdin.buffer.read()
    lines = run(data)
    if lines:
        sys.stdout.buffer.write(("\n".join(lines) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0
