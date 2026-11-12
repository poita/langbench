"""Command-line interface: read a program on stdin, print its output."""

from __future__ import annotations

import sys
from typing import Optional, Sequence

from .runner import run_program


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Run the program on stdin; always exit 0 (Scheme errors are output)."""
    source = sys.stdin.buffer.read().decode("utf-8")
    text = run_program(source)
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
