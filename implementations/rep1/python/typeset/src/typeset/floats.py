"""Floating figures: the figure block and its caption."""

from __future__ import annotations

from .context import Ctx, Env, text_units
from .inline import C, F, P, ROOT_STYLE
from .vlist import Line


class FigureBlock:
    """A figure laid out once, independent of where it is placed.

    ``frame`` is ``(x, width, height)`` or ``None``; the caption ``lines`` have
    baselines ``baselines[k]`` below the block's top.
    """

    def __init__(self, number: int, height: int, frame, lines: list[Line],
                 baselines: list[int]) -> None:
        self.number = number
        self.frame = frame
        self.lines = lines
        self.baselines = baselines
        self.height = height


def layout_figure(env: Env, node, number: int) -> FigureBlock:
    s = env.s
    W = node.width if node.width is not None else s.figure_width
    fw = W if W > 0 else s.body_width
    fx = s.body_x + (s.body_width - fw) // 2
    H = node.height
    units: list = []
    prefix = "".join(p[1] for p in s.figure_caption_prefix)
    if prefix:
        units.extend(text_units(prefix))
        units.append((P, ROOT_STYLE))
    units.extend((C, ch, ROOT_STYLE) for ch in f"{number}.")
    units.append((F, s.figure_caption_gap))
    units.extend(node.units)
    lines = env.lines_for(
        units, family=s.figure_caption_font, bold=False, italic=False,
        size=s.figure_caption_size, leading=s.figure_caption_leading, left=fx, measure=fw,
        first_indent=0, align=s.figure_caption_align, hyphenate=s.hyphenate)
    cursor = H + s.figure_caption_space
    baselines = []
    prev_baseline = prev_depth = 0
    for k, line in enumerate(lines):
        if k == 0:
            base = cursor + line.ascent
        else:
            base = prev_baseline + max(line.leading, prev_depth + s.line_skip + line.ascent)
        baselines.append(base)
        prev_baseline, prev_depth = base, line.depth
    height = prev_baseline + prev_depth
    frame = (fx, fw, H) if s.figure_frame else None
    return FigureBlock(number, height, frame, lines, baselines)
