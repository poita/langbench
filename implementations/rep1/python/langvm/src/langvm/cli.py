"""Command-line entry point: read a module stream on stdin, write the result on stdout."""

from __future__ import annotations

import sys

from .api import run_source


def main() -> int:
    """Run langvm.  The exit status is 0 for every Vellum-level outcome."""
    data = sys.stdin.buffer.read()
    result = run_source(data.decode("utf-8", errors="replace"))
    sys.stdout.buffer.write(result.output.encode("utf-8", errors="replace"))
    sys.stdout.buffer.flush()
    return 0
