"""Exception types raised by :mod:`tomlcodec`."""

from __future__ import annotations


class TomlError(Exception):
    """Base class for every error raised by this package."""


class TomlDecodeError(TomlError, ValueError):
    """The input is not a valid TOML 1.0.0 document.

    Attributes:
        msg: a short description of the problem.
        pos: offset (in characters) into the decoded text, or ``-1`` if unknown.
        lineno: 1-based line number, or ``0`` if unknown.
        colno: 1-based column number, or ``0`` if unknown.
    """

    def __init__(self, msg: str, text: str | None = None, pos: int = -1) -> None:
        self.msg = msg
        self.pos = pos
        if text is not None and pos >= 0:
            self.lineno = text.count("\n", 0, pos) + 1
            self.colno = pos - (text.rfind("\n", 0, pos) + 1) + 1
            super().__init__(f"{msg} (line {self.lineno}, column {self.colno})")
        else:
            self.lineno = 0
            self.colno = 0
            super().__init__(msg)


class TaggedJSONError(TomlError, ValueError):
    """The input is not a well-formed tagged-JSON tree."""
