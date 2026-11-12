"""Setting a broken list into lines: glue distribution, alignment, runs."""

from __future__ import annotations

from dataclasses import dataclass

from .fonts import FontLibrary, Face
from .hlist import BOX, GLUE, PENALTY, HList
from .linebreak import Breaking, Metrics, break_lines, BreakParams
from .units import distribute, scale
from .vlist import Line, Run


@dataclass
class Stats:
    """The counters of ``report.txt``."""

    lines: int = 0
    paragraphs: int = 0
    headings: int = 0
    tables: int = 0
    figures: int = 0
    footnotes: int = 0
    footnote_split_lines: int = 0
    hyphenated_lines: int = 0
    overfull_lines: int = 0
    emergency_lists: int = 0
    total_demerits: int = 0


class LineSetter:
    """Breaks horizontal lists and sets the resulting lines."""

    def __init__(self, params: BreakParams, stats: Stats) -> None:
        self.params = params
        self.stats = stats

    def break_and_set(self, hl: HList, *, left: int, measure: int, first_indent: int,
                      align: str, leading: int, face: Face, size: int) -> list[Line]:
        """Break *hl* and return its lines.

        ``face``/``size`` are the context's initial face and size, used for
        the metrics of a line with no text box.
        """
        brk = break_lines(hl.items, measure, first_indent, self.params)
        st = self.stats
        st.total_demerits += brk.total_demerits
        if brk.emergency:
            st.emergency_lists += 1
        out = []
        for a, b in brk.lines:
            out.append(self.set_line(hl, a, b, left=left, measure=measure,
                                     first_indent=first_indent, align=align,
                                     leading=leading, face=face, size=size))
        return out

    def set_line(self, hl: HList, a: int, b: int, *, left: int, measure: int,
                 first_indent: int, align: str, leading: int, face: Face, size: int) -> Line:
        items = hl.items
        first_line = a == 0
        L = measure - first_indent if first_line else measure
        left_line = left + first_indent if first_line else left
        start = 0 if first_line else a + 1
        while start < b and items[start].kind == GLUE:
            start += 1
        seg = items[start:b]
        pre = None
        endit = items[b]
        if endit.kind == PENALTY and endit.pre is not None:
            pre = endit.pre
        W = Y = Z = 0
        inf = False
        for it in seg:
            W += it.width
            if it.kind == GLUE:
                Y += it.stretch
                Z += it.shrink
                if it.inf:
                    inf = True
        if pre is not None:
            W += pre.width
        widths = [it.width for it in seg]
        if inf or align != "justify":
            if inf:
                widths = [0 if (it.kind == GLUE and it.inf) else it.width for it in seg]
        else:
            E = L - W
            if E == 0 or (E > 0 and Y == 0) or (E < 0 and Z == 0):
                pass
            elif E > 0:
                widths = self._spread(seg, widths, E, [it.stretch for it in seg])
            elif -E <= Z:
                widths = self._spread(seg, widths, E, [it.shrink for it in seg])
            else:
                widths = [it.width - it.shrink if it.kind == GLUE else it.width for it in seg]
        wset = sum(widths) + (pre.width if pre is not None else 0)
        if align == "right":
            x = left_line + L - wset
        elif align == "center":
            x = left_line + (L - wset) // 2
        else:
            x = left_line
        x0 = x
        runs: list[Run] = []
        fns = []
        ascent = None
        depth = 0
        cur: Run | None = None
        cur_frag = -1

        def add_box(it, x0):
            nonlocal cur, cur_frag, ascent, depth
            asc = scale(it.face.ascent, it.size) + it.raise_
            dep = max(0, scale(it.face.descent, it.size) - it.raise_)
            if ascent is None or asc > ascent:
                ascent = asc
            if dep > depth:
                depth = dep
            if cur is not None and cur_frag == it.frag:
                cur.text += it.text
                cur.width += it.width
            else:
                cur = Run(it.text, it.face.name, it.size, x0, it.width, it.raise_)
                cur_frag = it.frag
                runs.append(cur)
            if it.fn is not None:
                fns.append(it.fn)

        for it, w in zip(seg, widths):
            if it.kind == BOX:
                if it.face is not None:
                    add_box(it, x)
                else:
                    cur = None
                    cur_frag = -1
            elif it.kind == GLUE:
                cur = None
                cur_frag = -1
            x += w
        if pre is not None:
            add_box(pre, x)
        if ascent is None:
            ascent = scale(face.ascent, size)
            depth = scale(face.descent, size)
        st = self.stats
        if pre is not None:
            st.hyphenated_lines += 1
        if wset > L:
            st.overfull_lines += 1
        line = Line(runs, ascent, depth, leading, fns)
        line.x0 = x0
        line.wset = wset
        return line

    @staticmethod
    def _spread(seg, widths, E, weights):
        incr = distribute(E, weights)
        return [w + d for w, d in zip(widths, incr)]
