"""Shared layout environment: settings, fonts, hyphenation, list building."""

from __future__ import annotations

from dataclasses import dataclass, replace

from .fonts import Face, FontLibrary
from .hlist import BaseStyle, HListBuilder, HyphParams
from .inline import C, S, ROOT_STYLE
from .linebreak import BreakParams
from .lines import LineSetter, Stats
from .patterns import PatternLibrary
from .settings import Settings
from .units import scale
from .vlist import Line, Run

MIN_MEASURE = 1000


@dataclass(frozen=True)
class Ctx:
    """The layout context of a block (see "Contexts" in the specification)."""

    family: str
    size: int
    leading: int
    left: int
    measure: int
    align: str
    hyphenate: bool

    def with_(self, **kw) -> "Ctx":
        return replace(self, **kw)


def text_units(text: str) -> list:
    """Units for literal text: spaces collapse to glue, ends are trimmed."""
    out: list = []
    for ch in text:
        if ch == " ":
            if not out or out[-1][0] != S:
                out.append((S, ROOT_STYLE))
        else:
            out.append((C, ch, ROOT_STYLE))
    if out and out[-1][0] == S:
        out.pop()
    if out and out[0][0] == S:
        out.pop(0)
    return out


class Env:
    """Everything the layout stages share."""

    def __init__(self, settings: Settings, data_dir: str = "data") -> None:
        self.s = settings
        self.fonts = FontLibrary(data_dir)
        self.stats = Stats()
        patterns = PatternLibrary(data_dir).get(settings.hyphen_patterns) if settings.hyphenate else None
        self.builder = HListBuilder(
            self.fonts, settings.mark_size, settings.mark_raise,
            HyphParams(patterns, settings.hyphen_penalty, settings.ex_hyphen_penalty),
            settings.ragged_stretch)
        self.setter = LineSetter(
            BreakParams(settings.tolerance, settings.line_penalty, settings.adj_demerits,
                        settings.double_hyphen_demerits, settings.final_hyphen_demerits),
            self.stats)
        self._gid = 0

    def next_gid(self) -> int:
        self._gid += 1
        return self._gid

    def root_ctx(self) -> Ctx:
        s = self.s
        return Ctx(s.body_font, s.body_size, s.leading, s.body_x, s.body_width,
                   s.align, s.hyphenate)

    def face(self, family: str, bold: bool = False, italic: bool = False) -> Face:
        return self.fonts.resolve(family, bold, italic)

    def lines_for(self, units: list, *, family: str, bold: bool, italic: bool, size: int,
                  leading: int, left: int, measure: int, first_indent: int, align: str,
                  hyphenate: bool) -> list[Line]:
        """Build, break and set one horizontal list; lay out its footnotes."""
        hl = self.builder.build(units, BaseStyle(family, bold, italic, size), align, hyphenate)
        lines = self.setter.break_and_set(
            hl, left=left, measure=measure, first_indent=first_indent, align=align,
            leading=leading, face=self.face(family, bold, italic), size=size)
        for fn in hl.footnotes:
            self.layout_footnote(fn)
        return lines

    def layout_footnote(self, fn) -> None:
        if fn.lines:
            return
        s = self.s
        fn.lines = self.lines_for(
            fn.units, family=s.footnote_font, bold=False, italic=False, size=s.footnote_size,
            leading=s.footnote_leading, left=s.body_x + s.footnote_indent,
            measure=max(MIN_MEASURE, s.body_width - s.footnote_indent), first_indent=0,
            align=s.align, hyphenate=s.hyphenate)

    def pre_line(self, text: str, ctx: Ctx) -> Line:
        """One unbroken ``@pre`` line: a single box holding the whole text."""
        s = self.s
        left = ctx.left + s.pre_indent
        measure = max(MIN_MEASURE, ctx.measure - s.pre_indent)
        face = self.face(s.pre_font)
        size = s.pre_size
        if text:
            w = face.width(text, size)
            runs = [Run(text, face.name, size, left, w)]
        else:
            w = 0
            runs = []
        line = Line(runs, scale(face.ascent, size), scale(face.descent, size), s.pre_leading)
        line.x0 = left
        line.wset = w
        if w > measure:
            self.stats.overfull_lines += 1
        return line
