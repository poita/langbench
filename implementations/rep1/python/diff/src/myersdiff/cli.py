"""Command-line entry point: read a request on stdin, write the reply on stdout."""

from __future__ import annotations

import sys

from .protocol import ProtocolError, run


def main() -> int:
    data = sys.stdin.buffer.read().decode("utf-8", errors="surrogateescape")
    try:
        reply = run(data)
    except ValueError as exc:
        print(f"myersdiff: {exc}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(reply.encode("utf-8", errors="surrogateescape"))
    sys.stdout.buffer.flush()
    return 0


__all__ = ["main", "ProtocolError"]
