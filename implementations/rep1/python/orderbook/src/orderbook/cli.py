"""Command-line interface: commands on stdin, events on stdout."""

from __future__ import annotations

import sys
from typing import Optional, Sequence

from .engine import parse_stream, process

_CHUNK = 50_000  # output lines buffered per write


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Read the command stream from stdin and write events to stdout."""
    if argv is None:
        argv = sys.argv[1:]
    if argv:
        sys.stderr.write("usage: orderbook < commands > events\n")
        return 2
    text = sys.stdin.buffer.read().decode("ascii")
    out = sys.stdout.buffer
    buf: list[str] = []
    for line in process(parse_stream(text)):
        buf.append(line)
        if len(buf) >= _CHUNK:
            buf.append("")
            out.write("\n".join(buf).encode("ascii"))
            buf.clear()
    if buf:
        buf.append("")
        out.write("\n".join(buf).encode("ascii"))
    out.flush()
    return 0
