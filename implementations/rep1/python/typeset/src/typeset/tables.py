"""Table layout: column widths from cell measurements, and rows."""

from __future__ import annotations

from .context import Ctx, Env
from .hlist import BaseStyle
from .linebreak import Metrics, breakpoints
from .units import distribute
from .vlist import Glue, Row, Rule

_ALIGN = {"l": "left", "r": "right", "c": "center"}


def layout_table(env: Env, node, ctx: Ctx) -> list:
    """Return the vertical items of a ``@table``."""
    s = env.s
    cols = node.cols
    base = BaseStyle(ctx.family, False, False, ctx.size)
    face = env.face(ctx.family)

    # Build every cell's horizontal list once and measure it.
    rows = []
    nat = [0] * cols
    mn = [0] * cols
    for el in node.elements:
        if el[0] != "row":
            rows.append(None)
            continue
        cells = []
        for c, units in enumerate(el[1]):
            hl = env.builder.build(units, base, _ALIGN[node.aligns[c]], ctx.hyphenate)
            m = Metrics(hl.items)
            cell_nat = m.pw[len(hl.items)]
            bps = [0] + breakpoints(hl.items)
            cell_min = max(m.span(a, b)[0] for a, b in zip(bps, bps[1:]))
            nat[c] = max(nat[c], cell_nat)
            mn[c] = max(mn[c], cell_min)
            cells.append(hl)
        rows.append(cells)

    gap = s.table_col_gap
    avail = max(0, ctx.measure - (cols - 1) * gap)
    if sum(nat) <= avail:
        widths = list(nat)
    elif sum(mn) >= avail:
        widths = list(mn)
    else:
        diff = sum(nat) - avail
        slack = [nat[i] - mn[i] for i in range(cols)]
        incr = distribute(diff, slack)
        widths = [nat[i] - incr[i] for i in range(cols)]
    table_width = sum(widths) + (cols - 1) * gap
    xs = []
    x = ctx.left
    for w in widths:
        xs.append(x)
        x += w + gap

    items: list = []
    count = len(node.elements)
    prev_row = False
    for idx, el in enumerate(node.elements):
        if el[0] == "row":
            if prev_row:
                items.append(Glue(s.table_row_space))
            cell_lines = []
            for c, hl in enumerate(rows[idx]):
                lines = env.setter.break_and_set(
                    hl, left=xs[c], measure=widths[c], first_indent=0,
                    align=_ALIGN[node.aligns[c]], leading=s.table_leading, face=face,
                    size=ctx.size)
                for fn in hl.footnotes:  # cannot occur (the cell split precludes it)
                    env.layout_footnote(fn)
                cell_lines.append(lines)
            a_row = max(lines[0].ascent for lines in cell_lines)
            n_row = max(len(lines) for lines in cell_lines)
            d_row = max(lines[-1].depth for lines in cell_lines)
            height = a_row + (n_row - 1) * s.table_leading + d_row
            items.append(Row(height, a_row, s.table_leading, cell_lines))
            prev_row = True
        else:
            if idx > 0:
                items.append(Glue(s.table_rule_space))
            items.append(Rule(ctx.left, table_width, s.table_rule_thickness))
            if idx < count - 1:
                items.append(Glue(s.table_rule_space))
            prev_row = False
    return items
