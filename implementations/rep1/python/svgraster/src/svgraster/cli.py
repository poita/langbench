"""Command-line interface: ``svgraster <input-dir> <output-dir>``."""

from __future__ import annotations

import sys

from .batch import render_directory

USAGE = "usage: svgraster <input-dir> <output-dir>"


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    try:
        failures = render_directory(args[0], args[1])
    except (OSError, ValueError) as exc:
        print(f"svgraster: {exc}", file=sys.stderr)
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
