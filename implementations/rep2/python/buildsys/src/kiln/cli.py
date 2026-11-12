"""Command-line interface: ``kiln <input directory> <output directory>``."""

from __future__ import annotations

import sys
from typing import Sequence

from .session import run_session_dir

__all__ = ["main"]

USAGE = "usage: kiln <input directory> <output directory>\n"


def main(argv: Sequence[str] | None = None) -> int:
    """Run a session directory; returns the process exit status."""
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2 or args[0] in ("-h", "--help"):
        sys.stderr.write(USAGE)
        return 0 if args and args[0] in ("-h", "--help") else 2
    sys.setrecursionlimit(50000)
    run_session_dir(args[0], args[1])
    return 0
