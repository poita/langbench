"""Undo/redo bookkeeping. Entries store edits, never copies of the document."""

from __future__ import annotations

from typing import NamedTuple

from .cursor import CursorState
from .document import Position


class Replacement(NamedTuple):
    """One splice: *removed* was replaced by *inserted* at *start*.

    *start* is expressed in the document as it was immediately before this
    replacement was applied.
    """

    start: Position
    removed: str
    inserted: str


class UndoEntry(NamedTuple):
    """One edit command: the cursors around it and its replacements."""

    before: tuple[CursorState, ...]
    after: tuple[CursorState, ...]
    replacements: tuple[Replacement, ...]


class History:
    """Undo and redo stacks of :class:`UndoEntry`."""

    __slots__ = ("undo_stack", "redo_stack")

    def __init__(self) -> None:
        self.undo_stack: list[UndoEntry] = []
        self.redo_stack: list[UndoEntry] = []

    def record(self, entry: UndoEntry) -> None:
        """Push a new edit and clear the redo stack."""
        self.undo_stack.append(entry)
        self.redo_stack.clear()
