"""Command-line interface: hex DEFLATE stream on stdin, hex result on stdout."""

from __future__ import annotations

import sys
from typing import BinaryIO

from .decoder import inflate
from .errors import InflateError


def inflate_hex(text: str | bytes) -> str:
    """Decode a hex-encoded DEFLATE stream to a hex string.

    Surrounding whitespace is ignored.  Returns ``"error"`` if the stream is
    malformed.
    """
    if isinstance(text, bytes):
        text = text.decode("ascii")
    try:
        return inflate(bytes.fromhex(text.strip())).hex()
    except InflateError:
        return "error"


def main(stdin: BinaryIO | None = None, stdout: BinaryIO | None = None) -> int:
    """Run the tool; returns the process exit status (always 0 for valid use)."""
    stdin = stdin or sys.stdin.buffer
    stdout = stdout or sys.stdout.buffer
    stdout.write(inflate_hex(stdin.read()).encode("ascii") + b"\n")
    stdout.flush()
    return 0


def run() -> None:
    """Console-script entry point."""
    sys.exit(main())
