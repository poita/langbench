"""Cursors, selections and cursor-set normalization."""

from __future__ import annotations

from operator import attrgetter
from typing import NamedTuple

from .document import Position


class CursorState(NamedTuple):
    """The persistent part of a cursor (what undo entries remember)."""

    head: Position
    anchor: Position | None
    primary: bool


class Cursor:
    """A caret with an optional selection.

    Cursors are treated as immutable values. ``anchor`` is ``None`` unless the
    cursor has a selection, and is never equal to ``head``. ``goal`` is the
    column used by vertical movement.
    """

    __slots__ = ("head", "anchor", "primary", "goal", "start", "end")

    def __init__(
        self,
        head: Position,
        anchor: Position | None = None,
        primary: bool = False,
        goal: int | None = None,
    ) -> None:
        if anchor == head:
            anchor = None
        self.head = head
        self.anchor = anchor
        self.primary = primary
        self.goal = head[1] if goal is None else goal
        if anchor is None:
            self.start = self.end = head
        elif anchor < head:
            self.start, self.end = anchor, head
        else:
            self.start, self.end = head, anchor

    @property
    def has_selection(self) -> bool:
        return self.anchor is not None

    @property
    def state(self) -> CursorState:
        return CursorState(self.head, self.anchor, self.primary)

    def __repr__(self) -> str:
        sel = f", anchor={self.anchor}" if self.anchor is not None else ""
        flag = ", primary" if self.primary else ""
        return f"Cursor(head={self.head}{sel}{flag}, goal={self.goal})"


_get_start = attrgetter("start")
_get_end = attrgetter("end")


def normalize(cursors: list[Cursor]) -> list[Cursor]:
    """Sort cursors and merge colliding ones, returning the new list.

    Sorting is by range start ascending, then range end descending, stable.
    A point cursor merges with anything that touches or lies within it; two
    selections merge only when they genuinely overlap.
    """
    if len(cursors) < 2:
        return list(cursors)
    ordered = sorted(cursors, key=_get_end, reverse=True)  # stable, descending
    ordered.sort(key=_get_start)  # stable, ascending

    result: list[Cursor] = []
    cur = ordered[0]
    for c in ordered[1:]:
        if cur.anchor is None or c.anchor is None:
            joins = c.start <= cur.end
        else:
            joins = c.start < cur.end
        if not joins:
            result.append(cur)
            cur = c
            continue
        start = cur.start
        end = cur.end if cur.end >= c.end else c.end
        backward = cur.anchor is not None and cur.head == cur.start
        if backward:
            head, anchor = start, end
        else:
            head, anchor = end, start
        cur = Cursor(head, anchor, cur.primary or c.primary, cur.goal)
    result.append(cur)
    return result
