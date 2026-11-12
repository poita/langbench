"""Walking the block tree into the flat vertical list."""

from __future__ import annotations

from dataclasses import dataclass

from . import nodes
from .context import MIN_MEASURE, Ctx, Env
from .floats import FigureBlock, layout_figure
from .inline import C, F, R, S
from .tables import layout_table
from .units import alpha, roman
from .vlist import (HEADING, OTHER, FloatMark, ForceBreak, Glue, Rule, Run, group_lines)


@dataclass
class HeadingInfo:
    """A heading as the table of contents and running headers see it."""

    level: int
    number: str  # "" when unnumbered
    plain: str
    star: bool
    page: int | None = None  # body page (1-based) of its first line


def plain_text(units: list) -> str:
    """The plain text of an inline stream (styles dropped, spaces collapsed)."""
    out: list[str] = []
    for u in units:
        k = u[0]
        if k == C:
            out.append(u[1])
        elif k in (S, R):
            out.append(" ")
    text = "".join(out)
    while "  " in text:
        text = text.replace("  ", " ")
    return text.strip(" ")


def marker_text(ordered: bool, depth: int, number: int) -> str:
    m = depth % 3
    if not ordered:
        return ("•", "–", "*")[(m - 1) % 3]
    if m == 1:
        return f"{number}."
    if m == 2:
        return f"{alpha(number)}."
    return f"{roman(number)}."


class BlockLayout:
    """Lays out the body blocks, producing vertical items in source order."""

    def __init__(self, env: Env) -> None:
        self.env = env
        self.s = env.s
        self.items: list = []
        self.pend_max = 0
        self.pend_add = 0
        self.started = False
        self.counters = [0, 0, 0, 0]
        self.headings: list[HeadingInfo] = []
        self.figures: list[FigureBlock] = []

    def run(self, blocks: list) -> list:
        self.blocks(blocks, self.env.root_ctx(), 0)
        return self.items

    # -- spacing -----------------------------------------------------------

    def enter(self, space: int) -> None:
        self.pend_max = max(self.pend_max, space)

    leave = enter

    def leaf(self, before: int, after: int, items: list) -> None:
        self.pend_max = max(self.pend_max, before)
        total = self.pend_max + self.pend_add
        if self.started and total > 0:
            self.items.append(Glue(total))
        self.pend_max = after
        self.pend_add = 0
        self.items.extend(items)
        self.started = True

    def force_break(self) -> None:
        self.items.append(ForceBreak())
        self.pend_max = 0
        self.pend_add = 0

    # -- tree walk ---------------------------------------------------------

    def blocks(self, children: list, ctx: Ctx, depth: int) -> None:
        for node in children:
            self.block(node, ctx, depth)

    def block(self, node, ctx: Ctx, depth: int) -> None:
        s = self.s
        env = self.env
        if isinstance(node, nodes.Paragraph):
            env.stats.paragraphs += 1
            lines = env.lines_for(
                node.units, family=ctx.family, bold=False, italic=False, size=ctx.size,
                leading=ctx.leading, left=ctx.left, measure=ctx.measure,
                first_indent=s.par_indent, align=ctx.align, hyphenate=ctx.hyphenate)
            group_lines(lines, env.next_gid(), OTHER)
            self.leaf(s.par_space, s.par_space, lines)
        elif isinstance(node, nodes.Heading):
            self.heading(node, ctx)
        elif isinstance(node, nodes.Quote):
            self.enter(s.quote_space)
            inner = ctx.with_(left=ctx.left + s.quote_indent,
                              measure=max(MIN_MEASURE, ctx.measure - 2 * s.quote_indent))
            self.blocks(node.children, inner, depth)
            self.leave(s.quote_space)
        elif isinstance(node, nodes.Block):
            a = node.attrs
            inner = ctx.with_(
                align=a.get("align", ctx.align), size=a.get("size", ctx.size),
                leading=a.get("leading", ctx.leading), family=a.get("font", ctx.family),
                left=ctx.left + a.get("indent", 0),
                measure=max(MIN_MEASURE, ctx.measure - a.get("indent", 0) - a.get("right-indent", 0)))
            self.blocks(node.children, inner, depth)
        elif isinstance(node, nodes.ListNode):
            self.list_block(node, ctx, depth + 1)
        elif isinstance(node, nodes.Table):
            env.stats.tables += 1
            self.leaf(s.table_space, s.table_space, layout_table(env, node, ctx))
        elif isinstance(node, nodes.Pre):
            lines = [env.pre_line(text, ctx) for text in node.lines]
            group_lines(lines, env.next_gid(), OTHER)
            self.leaf(s.pre_space, s.pre_space, lines)
        elif isinstance(node, nodes.Figure):
            env.stats.figures += 1
            fig = layout_figure(env, node, len(self.figures) + 1)
            self.figures.append(fig)
            self.leaf(0, 0, [FloatMark(fig)])
        elif isinstance(node, nodes.Rule):
            self.leaf(s.rule_space, s.rule_space,
                      [Rule(ctx.left, ctx.measure, s.rule_thickness)])
        elif isinstance(node, nodes.VSpace):
            self.pend_add += node.height
        elif isinstance(node, nodes.NewPage):
            self.force_break()

    # -- headings ----------------------------------------------------------

    def heading(self, node: nodes.Heading, ctx: Ctx) -> None:
        s = self.s
        env = self.env
        env.stats.headings += 1
        level = node.level
        numbered = (not node.star) and s.heading_number
        number = ""
        units = list(node.units)
        if numbered:
            c = self.counters
            c[level - 1] += 1
            for m in range(level, 4):
                c[m] = 0
            number = ".".join(str(c[m]) for m in range(level))
            units = ([(C, ch, (False, False, False, "")) for ch in number]
                     + [(F, s.heading_number_gap)] + units)
        info = HeadingInfo(level, number, plain_text(node.units), node.star)
        self.headings.append(info)
        size = getattr(s, f"h{level}_size")
        leading = getattr(s, f"h{level}_leading")
        before = getattr(s, f"h{level}_space_before")
        after = getattr(s, f"h{level}_space_after")
        lines = env.lines_for(
            units, family=s.heading_font, bold=s.heading_bold, italic=s.heading_italic,
            size=size, leading=leading, left=ctx.left, measure=ctx.measure, first_indent=0,
            align=s.heading_align, hyphenate=ctx.hyphenate)
        group_lines(lines, env.next_gid(), HEADING, info)
        if level == 1 and s.h1_newpage:
            self.force_break()
        self.leaf(before, after, lines)

    # -- lists -------------------------------------------------------------

    def list_block(self, node: nodes.ListNode, ctx: Ctx, depth: int) -> None:
        s = self.s
        env = self.env
        self.enter(s.list_space)
        inner = ctx.with_(left=ctx.left + s.list_indent,
                          measure=max(MIN_MEASURE, ctx.measure - s.list_indent))
        for idx, item in enumerate(node.items):
            if idx > 0:
                self.enter(s.list_item_space)
            lines = env.lines_for(
                item.units, family=inner.family, bold=False, italic=False, size=inner.size,
                leading=inner.leading, left=inner.left, measure=inner.measure,
                first_indent=0, align=inner.align, hyphenate=inner.hyphenate)
            text = marker_text(node.ordered, depth, node.start + idx)
            face = env.face(inner.family)
            width = face.width(text, inner.size)
            lines[0].runs.append(Run(text, face.name, inner.size,
                                     inner.left - s.list_marker_gap - width, width))
            group_lines(lines, env.next_gid(), OTHER)
            self.leaf(0, 0, lines)
            self.blocks(item.children, inner, depth)
        self.leave(s.list_space)
