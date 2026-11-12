"""The line-oriented stdin/stdout protocol used by the command-line tool."""

from __future__ import annotations

from .myers import diff
from .patch import patch
from .script import format_script, parse_script_lines


class ProtocolError(ValueError):
    """Malformed input."""


class _Reader:
    def __init__(self, text: str) -> None:
        self.lines = text.split("\n")
        self.pos = 0

    def next(self) -> str:
        if self.pos >= len(self.lines):
            raise ProtocolError("unexpected end of input")
        line = self.lines[self.pos]
        self.pos += 1
        return line

    def count(self) -> int:
        s = self.next().strip(" \t")
        if not s.isascii() or not s.isdigit():
            raise ProtocolError(f"bad count line {s!r}")
        return int(s)

    def block(self, n: int) -> list[str]:
        if self.pos + n > len(self.lines):
            raise ProtocolError("unexpected end of input")
        chunk = self.lines[self.pos : self.pos + n]
        self.pos += n
        return chunk


def run(text: str) -> str:
    """Process a complete request (``diff`` or ``patch``) and return the reply."""
    if "\r" in text:  # content lines never contain \r, so \r\n is line ending
        text = text.replace("\r\n", "\n")
    r = _Reader(text)
    mode = r.next().strip(" \t")
    a = r.block(r.count())
    if mode == "diff":
        b = r.block(r.count())
        return format_script(diff(a, b))
    if mode == "patch":
        script = parse_script_lines(r.block(r.count()))
        out = patch(a, script, strict=False)
        return "".join([str(len(out)), "\n", *[s + "\n" for s in out]])
    raise ProtocolError(f"unknown mode {mode!r}")
