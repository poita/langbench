"""The table of contents: entries, leaders, page labels."""

from __future__ import annotations

from .blocks import BlockLayout, HeadingInfo
from .context import Env, text_units
from .inline import C, F, ROOT_STYLE
from .settings import text_literal
from .vlist import OTHER, Run, group_lines


def toc_items(env: Env, title: str | None, entries: list[HeadingInfo], page_label) -> list:
    """Build the TOC's vertical list.  ``page_label(page)`` gives an entry's label."""
    s = env.s
    layout = BlockLayout(env)
    if title is None:
        title = text_literal(s.toc_title)
    lines = env.lines_for(
        text_units(title), family=s.toc_title_font, bold=s.heading_bold,
        italic=s.heading_italic, size=s.toc_title_size, leading=s.h1_leading,
        left=s.body_x, measure=s.body_width, first_indent=0, align=s.heading_align,
        hyphenate=s.hyphenate)
    group_lines(lines, env.next_gid(), OTHER)
    layout.leaf(0, s.toc_title_space_after, lines)

    face = env.face(s.toc_font)
    size = s.toc_size
    leader = text_literal(s.toc_leader)
    unit = face.width(leader, size)
    for e in entries:
        indent = (e.level - 1) * s.toc_indent
        units: list = []
        if e.number:
            units.extend((C, ch, ROOT_STYLE) for ch in e.number)
            units.append((F, s.toc_number_gap))
        units.extend(text_units(e.plain))
        left = s.body_x + indent
        lines = env.lines_for(
            units, family=s.toc_font, bold=False, italic=False, size=size,
            leading=s.toc_leading, left=left, measure=s.body_width - indent - s.toc_reserve,
            first_indent=0, align="left", hyphenate=s.hyphenate)
        last = lines[-1]
        label = page_label(e.page)
        lw = face.width(label, size)
        label_x = s.body_x + s.body_width - lw
        x_from = last.x0 + last.wset + s.toc_leader_gap
        x_to = label_x - s.toc_leader_gap
        k = max(0, (x_to - x_from) // unit)
        if k > 0:
            last.runs.append(Run(leader * k, face.name, size, x_to - k * unit, k * unit))
        last.runs.append(Run(label, face.name, size, label_x, lw))
        group_lines(lines, env.next_gid(), OTHER)
        layout.leaf(s.toc_entry_space, s.toc_entry_space, lines)
    return layout.items
