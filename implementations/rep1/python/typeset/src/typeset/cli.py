"""Command-line interface: ``python -m typeset <input dir> <output dir>``."""

from __future__ import annotations

import sys

from .engine import typeset_directory


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        print("usage: typeset <input directory> <output directory>", file=sys.stderr)
        return 2
    typeset_directory(args[0], args[1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
