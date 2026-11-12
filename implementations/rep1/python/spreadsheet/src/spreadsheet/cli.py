"""Command-line interface: reads commands on stdin, writes results to stdout."""

from __future__ import annotations

import sys
from typing import Iterable

from .sheet import Sheet

__all__ = ["run_commands", "main"]


def run_commands(lines: Iterable[str], sheet: Sheet | None = None) -> list[str]:
    """Execute command *lines* and return the output lines.

    Commands are ``set <CELL> <content>``, ``get <CELL>``, ``clear <CELL>`` and
    ``dump``; only ``get`` and ``dump`` produce output.
    """
    sheet = Sheet() if sheet is None else sheet
    out: list[str] = []
    for line in lines:
        parts = line.split(" ", 2)
        cmd = parts[0]
        if cmd == "set":
            sheet.set(parts[1], parts[2])
        elif cmd == "get":
            out.append(sheet.get(parts[1]))
        elif cmd == "clear":
            sheet.clear(parts[1])
        elif cmd == "dump":
            out.extend(f"{name} {shown}" for name, shown in sheet.dump())
        else:
            raise ValueError(f"unknown command: {line!r}")
    return out


def main(argv: list[str] | None = None) -> int:
    data = sys.stdin.buffer.read().decode("utf-8")
    # Split on "\n" only: str.splitlines() would also split on other
    # separators that may legitimately occur inside string literals.
    lines = data.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    out = run_commands(lines)
    if out:
        sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()
    return 0
