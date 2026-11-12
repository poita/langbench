"""Command-line interface: read a program, print one line per declaration."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

from . import __version__
from .errors import ParseError
from .infer import Inferencer
from .parser import Parser
from .lexer import tokenize
from .runtime import run_deep


def _check(source: str) -> tuple[str, int]:
    """Return (output text, exit status) for ``source``."""
    out: list[str] = []
    inferencer = Inferencer()
    try:
        parser = Parser(tokenize(source))
        while not parser.at_end():
            out.append(inferencer.check_decl(parser.parse_decl()).render())
            out.append("\n")
    except ParseError as exc:
        print(f"typeinfer: syntax error: {exc}", file=sys.stderr)
        return "".join(out), 2
    return "".join(out), 0


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="typeinfer",
        description="Print the principal type of every declaration of an ML-like "
        "program read from FILE (default: standard input).",
    )
    ap.add_argument("file", nargs="?", default="-", help="source file, or - for stdin")
    ap.add_argument("--version", action="version", version=f"typeinfer {__version__}")
    args = ap.parse_args(argv)

    if args.file == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(args.file, "rb") as f:
            data = f.read()
    source = data.decode("utf-8", errors="replace")
    text, status = run_deep(lambda: _check(source))
    sys.stdout.write(text)
    sys.stdout.flush()
    return status
