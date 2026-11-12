"""Command-line interface: canonicalise the JSON document on stdin.

Prints the canonical form followed by a newline, or ``invalid`` if the
document is not valid.  The exit status is 0 in both cases.
"""

from __future__ import annotations

import sys

from . import canonicalize
from .errors import JSONError


def main(argv: list[str] | None = None) -> int:
    data = sys.stdin.buffer.read()
    try:
        result = canonicalize(data)
    except JSONError:
        result = b"invalid"
    sys.stdout.buffer.write(result + b"\n")
    sys.stdout.buffer.flush()
    return 0
