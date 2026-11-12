"""Command-line interface: read a document and commands on stdin, print on stdout."""

from __future__ import annotations

import sys
from collections.abc import Sequence

from .buffer import TextBuffer
from .commands import CommandError, Interpreter, parse_input


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point. Takes no arguments; reads stdin, writes stdout."""
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        print("usage: textbuffer < input", file=sys.stderr)
        return 2
    data = sys.stdin.buffer.read().decode("utf-8")
    try:
        lines, commands = parse_input(data)
        buffer = TextBuffer.from_lines(lines)
        Interpreter(buffer, sys.stdout).run_all(commands)
    except CommandError as exc:
        sys.stdout.flush()
        print(f"textbuffer: {exc}", file=sys.stderr)
        return 1
    sys.stdout.flush()
    return 0
