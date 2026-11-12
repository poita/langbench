"""Command-line interface: ``mimedump <input path> <output directory>``."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from . import __version__
from .report import dump_mailbox


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mimedump",
        description=(
            "Parse every message of an mbox file or a directory of .eml files and "
            "write a text dump of each, plus the decoded attachments, to a directory."
        ),
    )
    parser.add_argument("input", help="an mbox file, or a directory of .eml files")
    parser.add_argument("output", help="output directory (created if missing)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the tool; returns the process exit status."""
    args = build_parser().parse_args(argv)
    try:
        dump_mailbox(args.input, args.output)
    except OSError as exc:
        print(f"mimedump: {exc}", file=sys.stderr)
        return 1
    return 0
