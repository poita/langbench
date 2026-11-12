"""Command-line entry point: read commands on stdin, print results."""

from __future__ import annotations

import sys

from .commands import run


def process(text: str) -> str:
    """Process a complete input document and return the complete output."""
    lines = text.split("\n")
    count = int(lines[0]) if lines and lines[0].strip() else 0
    out = list(run(lines[1 : 1 + count]))
    return "\n".join(out) + "\n" if out else ""


def main() -> int:
    data = sys.stdin.buffer.read().decode("ascii")
    sys.stdout.buffer.write(process(data).encode("ascii"))
    sys.stdout.buffer.flush()
    return 0
