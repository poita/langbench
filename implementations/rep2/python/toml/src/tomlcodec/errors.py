"""Exception types raised by :mod:`tomlcodec`."""

from __future__ import annotations


class TomlDecodeError(ValueError):
    """The document is not valid TOML 1.0.0.

    Attributes:
        msg: Short description of the problem.
        offset: Character offset into the decoded text where the problem was
            detected, or ``None`` when no position is known.
        line: 1-based line number of ``offset`` (``None`` if unknown).
        column: 1-based column of ``offset`` (``None`` if unknown).
    """

    def __init__(self, msg: str, offset: int | None = None, text: str | None = None):
        self.msg = msg
        self.offset = offset
        self.line: int | None = None
        self.column: int | None = None
        if offset is not None and text is not None:
            self.locate(offset, text)
        super().__init__(self._format())

    def locate(self, offset: int, text: str) -> None:
        """Record ``offset`` and derive the line and column from ``text``."""
        self.offset = offset
        self.line = text.count("\n", 0, offset) + 1
        self.column = offset - (text.rfind("\n", 0, offset) + 1) + 1
        self.args = (self._format(),)

    def _format(self) -> str:
        if self.line is not None:
            return f"{self.msg} (line {self.line}, column {self.column})"
        return self.msg


class TaggedJsonError(ValueError):
    """The input is not a well-formed tagged JSON tree."""
