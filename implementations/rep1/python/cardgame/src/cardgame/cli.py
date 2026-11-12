"""Command-line entry point: match file on stdin, event log on stdout."""

from __future__ import annotations

import sys

from .runner import run_match


def main(argv: list[str] | None = None) -> int:
    data = sys.stdin.buffer.read()
    text = data.decode("utf-8", errors="replace")
    sys.stdout.write(run_match(text))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
