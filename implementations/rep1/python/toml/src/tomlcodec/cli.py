"""Command-line interface.

Reads ``decode`` or ``encode`` on the first line of stdin and the document on
the rest. ``decode`` prints tagged JSON (or ``error`` for an invalid
document); ``encode`` prints canonical TOML.
"""

from __future__ import annotations

import sys
from typing import BinaryIO

from .encoder import dumps
from .errors import TomlError
from .parser import loads
from .tagged import from_tagged_json, to_tagged_json


def run(data: bytes) -> bytes:
    """Process one request (mode line plus document) and return the output bytes."""
    mode_line, _, document = data.partition(b"\n")
    mode = mode_line.strip()
    if mode == b"decode":
        try:
            result = to_tagged_json(loads(document))
        except (TomlError, MemoryError):
            result = "error"
    elif mode == b"encode":
        try:
            result = dumps(from_tagged_json(document.decode("utf-8")))
        except (TomlError, UnicodeDecodeError):
            result = "error"
    else:
        raise SystemExit(f"tomlcodec: unknown mode {mode_line!r} (expected 'decode' or 'encode')")
    if not result.endswith("\n"):
        result += "\n"
    return result.encode("utf-8")


def main(stdin: BinaryIO | None = None, stdout: BinaryIO | None = None) -> int:
    # Deeply nested documents recurse once or twice per level.
    sys.setrecursionlimit(max(sys.getrecursionlimit(), 100_000))
    data = (stdin or sys.stdin.buffer).read()
    out = stdout or sys.stdout.buffer
    out.write(run(data))
    out.flush()
    return 0
