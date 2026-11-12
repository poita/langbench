"""Vertical items: the things a page is made of."""

from __future__ import annotations

HEADING, OTHER = 0, 1

# Item kinds (class attribute ``kind``).
LINE, GLUE, RULE, ROW, FRAME, FLOATMARK, FORCEBREAK = range(7)


class Run:
    """One placed ``text`` item: ``x`` is the left edge, ``raise_`` is subtracted
    from the line's baseline."""

    __slots__ = ("text", "face", "size", "x", "width", "raise_")

    def __init__(self, text, face, size, x, width, raise_=0):
        self.text = text
        self.face = face
        self.size = size
        self.x = x
        self.width = width
        self.raise_ = raise_


class Line:
    """A set line of text with its vertical metrics and group identity."""

    kind = LINE
    __slots__ = ("runs", "ascent", "depth", "leading", "gid", "k", "n", "gkind",
                 "fns", "heading", "x0", "wset")

    def __init__(self, runs, ascent, depth, leading, fns=()):
        self.runs = runs
        self.ascent = ascent
        self.depth = depth
        self.leading = leading
        self.gid = -1
        self.k = 1
        self.n = 1
        self.gkind = OTHER
        self.fns = fns
        self.heading = None
        self.x0 = 0
        self.wset = 0


class Glue:
    kind = GLUE
    __slots__ = ("height",)

    def __init__(self, height):
        self.height = height


class Rule:
    kind = RULE
    __slots__ = ("x", "width", "thickness")

    def __init__(self, x, width, thickness):
        self.x = x
        self.width = width
        self.thickness = thickness


class Row:
    """A table row: ``cells`` is a list of lines per cell, with baselines at
    ``a_row + k * table_leading`` below the row top."""

    kind = ROW
    __slots__ = ("height", "a_row", "table_leading", "cells")

    def __init__(self, height, a_row, table_leading, cells):
        self.height = height
        self.a_row = a_row
        self.table_leading = table_leading
        self.cells = cells


class FloatMark:
    kind = FLOATMARK
    __slots__ = ("figure",)

    def __init__(self, figure):
        self.figure = figure


class ForceBreak:
    kind = FORCEBREAK
    __slots__ = ()


def group_lines(lines: list[Line], gid: int, gkind: int, heading=None) -> None:
    """Stamp a group identity on the lines of one horizontal list."""
    n = len(lines)
    for k, line in enumerate(lines, 1):
        line.gid = gid
        line.k = k
        line.n = n
        line.gkind = gkind
        line.heading = heading
