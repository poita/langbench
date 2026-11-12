"""The document: a sequence of lines addressed by (line, column) positions."""

from __future__ import annotations

from collections.abc import Iterable

Position = tuple[int, int]
"""A ``(line, col)`` pair, both 0-based. Positions order lexicographically."""


def advance(start: Position, text: str) -> Position:
    """Return the position reached by writing *text* starting at *start*."""
    line, col = start
    newlines = text.count("\n")
    if newlines == 0:
        return (line, col + len(text))
    return (line + newlines, len(text) - text.rfind("\n") - 1)


class Document:
    """A text document stored as a list of lines (without newline characters).

    A document always has at least one line. Edits are expressed as
    :meth:`replace` calls on a range of positions; a replacement costs
    O(line length + text length) within a line, plus O(number of lines) when
    the number of lines changes.
    """

    __slots__ = ("_lines",)

    def __init__(self, lines: Iterable[str] = ()) -> None:
        self._lines: list[str] = list(lines) or [""]

    @classmethod
    def from_text(cls, text: str) -> Document:
        """Build a document from text whose lines are separated by ``\\n``."""
        return cls(text.split("\n"))

    # -- queries ---------------------------------------------------------

    @property
    def line_count(self) -> int:
        return len(self._lines)

    @property
    def lines(self) -> tuple[str, ...]:
        """A snapshot of the document's lines."""
        return tuple(self._lines)

    @property
    def text(self) -> str:
        """The whole document, lines joined by a single ``\\n``."""
        return "\n".join(self._lines)

    def line(self, index: int) -> str:
        return self._lines[index]

    def line_length(self, index: int) -> int:
        return len(self._lines[index])

    @property
    def end(self) -> Position:
        """The position at the very end of the document."""
        last = len(self._lines) - 1
        return (last, len(self._lines[last]))

    def clamp(self, line: int, col: int) -> Position:
        """Clamp *line* to the document, then *col* to that line."""
        line = max(0, min(line, len(self._lines) - 1))
        col = max(0, min(col, len(self._lines[line])))
        return (line, col)

    def slice(self, start: Position, end: Position) -> str:
        """Return the text between two positions (``start <= end``)."""
        (sl, sc), (el, ec) = start, end
        lines = self._lines
        if sl == el:
            return lines[sl][sc:ec]
        middle = lines[sl + 1 : el]
        return "\n".join([lines[sl][sc:], *middle, lines[el][:ec]])

    # -- editing ---------------------------------------------------------

    def replace(self, start: Position, end: Position, text: str) -> tuple[str, Position]:
        """Replace the range ``[start, end]`` by *text*.

        Returns ``(removed_text, new_end)`` where *new_end* is the position
        just after the inserted text.
        """
        sl, sc = start
        el, ec = end
        lines = self._lines
        first = lines[sl]
        if sl == el:
            removed = first[sc:ec]
            if "\n" not in text:
                lines[sl] = first[:sc] + text + first[ec:]
                return removed, (sl, sc + len(text))
            tail = first[ec:]
        else:
            last = lines[el]
            removed = "\n".join([first[sc:], *lines[sl + 1 : el], last[:ec]])
            tail = last[ec:]
        parts = text.split("\n")
        head = first[:sc]
        if len(parts) == 1:
            lines[sl : el + 1] = [head + text + tail]
            return removed, (sl, sc + len(text))
        final = parts[-1]
        parts[0] = head + parts[0]
        parts[-1] = final + tail
        lines[sl : el + 1] = parts
        return removed, (sl + len(parts) - 1, len(final))
