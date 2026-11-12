"""Command-line interface: ``sitegen <input directory> <output directory>``."""

from __future__ import annotations

import gc
import sys
from collections.abc import Sequence

from .errors import SitegenError
from .generator import generate

USAGE = "usage: sitegen <input directory> <output directory>"


def main(argv: Sequence[str] | None = None) -> int:
    """Run the tool; returns the process exit status."""
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2 or args[0] in ("-h", "--help"):
        stream = sys.stdout if args[:1] in (["-h"], ["--help"]) else sys.stderr
        print(USAGE, file=stream)
        return 0 if stream is sys.stdout else 2
    # The parsers build many small linked objects that live until the end of
    # the run; the cycle collector would only slow them down.
    gc.disable()
    try:
        generate(args[0], args[1])
    except (SitegenError, OSError, UnicodeDecodeError) as exc:
        print(f"sitegen: error: {exc}", file=sys.stderr)
        return 1
    return 0
