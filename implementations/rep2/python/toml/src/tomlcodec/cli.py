"""Command-line interface.

Reads one line naming the mode (``decode`` or ``encode``) from stdin followed
by the document, and writes the result to stdout.  In decode mode an invalid
document prints ``error``; the exit status is 0 either way.
"""

from __future__ import annotations

import sys
from typing import Sequence

from . import decode, encode
from .errors import TomlDecodeError

# Parsing and writing are recursive; deeply nested documents need headroom.
RECURSION_LIMIT = 20000


def run(raw: bytes) -> bytes:
    """Process one request (mode line + document) and return the output."""
    mode, newline, document = raw.partition(b"\n")
    if not newline or mode not in (b"decode", b"encode"):
        raise ValueError("first line must be 'decode' or 'encode'")
    if mode == b"decode":
        try:
            result = decode(document)
        except TomlDecodeError:
            result = "error"
    else:
        result = encode(document)
    return (result.rstrip("\n") + "\n").encode("utf-8")


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args:
        sys.stderr.write(
            "usage: python -m tomlcodec < input\n"
            "  input: a line 'decode' or 'encode', then the document\n"
        )
        return 2
    sys.setrecursionlimit(RECURSION_LIMIT)
    try:
        output = run(sys.stdin.buffer.read())
    except ValueError as exc:
        sys.stderr.write(f"tomlcodec: {exc}\n")
        return 2
    sys.stdout.buffer.write(output)
    sys.stdout.buffer.flush()
    return 0
