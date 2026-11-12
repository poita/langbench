"""Command-line interface: registry and root manifest on stdin, result on stdout."""

from __future__ import annotations

import sys
from collections.abc import Sequence

from .registry import parse_input
from .resolver import format_resolution, resolve


def main(argv: Sequence[str] | None = None) -> int:
    """Read the whole of stdin, resolve, print the resolution."""
    registry, root = parse_input(sys.stdin.buffer.read().decode("ascii"))
    sys.stdout.write(format_resolution(resolve(registry, root)))
    sys.stdout.flush()
    return 0
