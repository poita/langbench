"""Command-line interface: Markdown from a file or stdin to HTML on stdout."""

from __future__ import annotations

import argparse
import gc
import sys

from . import __version__
from .api import convert


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cmarkpy",
        description="Convert CommonMark to HTML. Reads stdin unless FILE is given.",
    )
    parser.add_argument("file", nargs="?", default="-", metavar="FILE", help="input file ('-' or omitted: stdin)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.file == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(args.file, "rb") as fh:
            data = fh.read()
    # A one-shot process: the cyclic collector would only slow the run down.
    gc.disable()
    html = convert(data.decode("utf-8", errors="replace"))
    sys.stdout.buffer.write(html.encode("utf-8", errors="replace"))
    sys.stdout.buffer.flush()
    return 0
