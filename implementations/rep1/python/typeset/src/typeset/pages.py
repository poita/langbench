"""Page breaking: cut selection, footnote areas, floats and page assembly."""

from __future__ import annotations

from .context import Env
from .output import Page, box_item, rule_item, text_item
from .vlist import FLOATMARK, FORCEBREAK, GLUE, HEADING, LINE, ROW, RULE


class FnGroup:
    """The lines of one footnote (or the unplaced tail of one)."""

    __slots__ = ("fn", "lines", "marked")

    def __init__(self, fn, lines, marked: bool) -> None:
        self.fn = fn
        self.lines = lines
        self.marked = marked


class Stack:
    """Vertical-placement accumulator (used for footnote stacks)."""

    def __init__(self, item_space: int, line_skip: int) -> None:
        self.item_space = item_space
        self.line_skip = line_skip
        self.cursor = 0
        self.fresh = True
        self.prev_baseline = 0
        self.prev_depth = 0
        self.groups = 0
        self.lines = 0

    def start_group(self) -> None:
        if self.groups:
            self.cursor += self.item_space
            self.fresh = True
        self.groups += 1

    def add_line(self, line) -> int:
        """Advance over *line*; return its baseline (relative to the stack top)."""
        if self.fresh:
            baseline = self.cursor + line.ascent
        else:
            baseline = self.prev_baseline + max(line.leading,
                                                self.prev_depth + self.line_skip + line.ascent)
        self.cursor = baseline + line.depth
        self.prev_baseline = baseline
        self.prev_depth = line.depth
        self.fresh = False
        self.lines += 1
        return baseline

    def add_group(self, lines) -> None:
        self.start_group()
        for line in lines:
            self.add_line(line)


def compute_legal(items: list, orphans: int, widows: int, keep: bool) -> list[bool]:
    """``legal[j]``: may a page break occur before item *j* (``j == n`` is the end)."""
    n = len(items)
    legal = [True] * (n + 1)
    legal[0] = False
    for j, it in enumerate(items):
        if it.kind != LINE:
            continue
        k = it.k
        if it.gkind == HEADING:
            if k != 1:
                legal[j] = False
        elif k > 1 and not (k - 1 >= orphans and it.n - k + 1 >= widows):
            legal[j] = False
    if keep:
        idx = 0
        while idx < n:
            it = items[idx]
            if it.kind == LINE and it.gkind == HEADING and it.k == 1:
                last = idx + it.n - 1
                for p in range(idx + 1, last + 1):
                    legal[p] = False
                j = last + 1
                while j < n and items[j].kind in (GLUE, FLOATMARK):
                    legal[j] = False
                    j += 1
                if j < n:
                    legal[j] = False
                idx = last + 1
            else:
                idx += 1
    return legal


class Paginator:
    """Paginates a vertical list; see "Page breaking" in the specification."""

    def __init__(self, env: Env, items: list, *, label_of, front: bool) -> None:
        self.env = env
        self.s = env.s
        self.items = items
        self.label_of = label_of
        self.front = front
        s = self.s
        self.legal = compute_legal(items, s.orphans, s.widows, s.keep_with_next)

    def new_stack(self) -> Stack:
        return Stack(self.s.footnote_item_space, self.s.line_skip)

    def paginate(self) -> list[Page]:
        s = self.s
        V = self.items
        n = len(V)
        pages: list[Page] = []
        queue: list = []
        carried: list[FnGroup] = []
        i = 0
        while True:
            while i < n and V[i].kind in (GLUE, FORCEBREAK):
                i += 1
            if i == n and not queue and not carried:
                break
            label, value = self.label_of(len(pages) + 1)
            page = Page(label, value, self.front)
            pages.append(page)
            # 1. floats
            taken = []
            zone = 0
            while queue:
                fig = queue[0]
                z1 = zone + fig.height + s.float_space_after
                if i < n:
                    ok = s.body_height - z1 >= s.float_min_body
                else:
                    ok = not taken or z1 <= s.body_height
                if not ok:
                    break
                taken.append(queue.pop(0))
                zone = z1
            body_top = s.body_y + zone
            goal = s.body_height - zone
            # 2./3. cut
            cut = self.choose_cut(i, goal, carried) if i < n else n
            # 4. body
            end = cut
            while end > i and V[end - 1].kind == GLUE:
                end -= 1
            body_empty = end == i
            used = self.place_body(page, i, end, body_top, len(pages))
            # 5. footnotes
            fns = []
            for it in V[i:end]:
                if it.kind == LINE:
                    fns.extend(it.fns)
            candidates = carried + [FnGroup(fn, fn.lines, True) for fn in fns]
            carried = self.place_footnotes(page, candidates, goal - used, body_empty)
            # floats output
            y = s.body_y
            for fig in taken:
                self.place_figure(page, fig, y)
                y += fig.height + s.float_space_after
            # 6. queue figures
            for it in V[i:cut]:
                if it.kind == FLOATMARK:
                    queue.append(it.figure)
            i = cut
        return pages

    # -- cut selection -----------------------------------------------------

    def choose_cut(self, i: int, goal: int, carried: list[FnGroup]) -> int:
        s = self.s
        V = self.items
        n = len(V)
        legal = self.legal
        fn_stack = self.new_stack()
        for g in carried:
            fn_stack.add_group(g.lines)
        fixed = s.footnote_space_before + s.footnote_rule_thickness + s.footnote_space_after
        max_h = s.footnote_max_height
        line_skip = s.line_skip
        cursor = 0
        fresh = True
        prev_baseline = prev_depth = 0
        used_body = 0
        best = None
        for j in range(i + 1, n + 1):
            it = V[j - 1]
            kind = it.kind
            if kind == FORCEBREAK:
                return j - 1
            if kind == LINE:
                if fresh:
                    baseline = cursor + it.ascent
                else:
                    baseline = prev_baseline + max(it.leading, prev_depth + line_skip + it.ascent)
                cursor = baseline + it.depth
                prev_baseline = baseline
                prev_depth = it.depth
                fresh = False
                for fn in it.fns:
                    fn_stack.add_group(fn.lines)
                used_body = cursor
            elif kind == GLUE:
                cursor += it.height
                fresh = True
            elif kind == FLOATMARK:
                used_body = cursor
            else:  # RULE, ROW, FRAME
                h = it.thickness if kind == RULE else it.height
                cursor += h
                fresh = True
                used_body = cursor
            if fn_stack.lines:
                a_fn = min(fixed + fn_stack.cursor, max_h)
            else:
                a_fn = 0
            used = used_body + a_fn
            if used <= goal and legal[j]:
                best = j
            if used > goal:
                break
        if best is not None:
            return best
        for j in range(i + 1, n + 1):
            if V[j - 1].kind == FORCEBREAK:
                return j - 1
            if legal[j]:
                return j
        return n

    # -- placement ---------------------------------------------------------

    def place_body(self, page: Page, i: int, end: int, body_top: int, page_no: int) -> int:
        """Place items ``i..end-1``; return the used body height."""
        s = self.s
        V = self.items
        stats = self.env.stats
        out = page.items
        region = "body"
        cursor = body_top
        fresh = True
        prev_baseline = prev_depth = 0
        for it in V[i:end]:
            kind = it.kind
            if kind == LINE:
                if fresh:
                    baseline = cursor + it.ascent
                else:
                    baseline = prev_baseline + max(it.leading,
                                                   prev_depth + s.line_skip + it.ascent)
                for r in it.runs:
                    out.append(text_item(region, r.face, r.size, r.x, baseline - r.raise_,
                                         r.width, r.text))
                stats.lines += 1
                cursor = baseline + it.depth
                prev_baseline = baseline
                prev_depth = it.depth
                fresh = False
                if it.heading is not None and it.k == 1:
                    it.heading.page = page_no
                    page.headings.append(it.heading)
            elif kind == GLUE:
                cursor += it.height
                fresh = True
            elif kind == RULE:
                out.append(rule_item(region, it.x, cursor, it.width, it.thickness))
                cursor += it.thickness
                fresh = True
            elif kind == ROW:
                for lines in it.cells:
                    for k, line in enumerate(lines):
                        base = cursor + it.a_row + k * it.table_leading
                        for r in line.runs:
                            out.append(text_item(region, r.face, r.size, r.x,
                                                 base - r.raise_, r.width, r.text))
                        stats.lines += 1
                cursor += it.height
                fresh = True
        return cursor - body_top

    def place_figure(self, page: Page, fig, y: int) -> None:
        out = page.items
        stats = self.env.stats
        if fig.frame is not None:
            fx, fw, fh = fig.frame
            out.append(box_item("float", fx, y, fw, fh))
        for line, rel in zip(fig.lines, fig.baselines):
            base = y + rel
            for r in line.runs:
                out.append(text_item("float", r.face, r.size, r.x, base - r.raise_, r.width, r.text))
            stats.lines += 1

    def place_footnotes(self, page: Page, groups: list[FnGroup], avail_body: int,
                        body_empty: bool) -> list[FnGroup]:
        """Choose and place the footnote lines of a page; return the carry-over."""
        if not groups:
            return []
        s = self.s
        env = self.env
        avail = avail_body - s.footnote_space_before - s.footnote_rule_thickness \
            - s.footnote_space_after
        stack = self.new_stack()
        flat = []  # (group index, line index, stack height after the line)
        for gi, g in enumerate(groups):
            stack.start_group()
            for li, line in enumerate(g.lines):
                stack.add_line(line)
                flat.append((gi, li, stack.cursor))
        m = 0
        for gi, li, h in flat:
            if h <= avail:
                m += 1
            else:
                break
        if m:
            gi, li, _ = flat[m - 1]
            if li + 1 < len(groups[gi].lines) and li + 1 < s.footnote_min_split:
                first = next(t for t, f in enumerate(flat) if f[0] == gi)
                if first > 0:
                    m = first
        if body_empty and m == 0 and flat:
            m = 1
        if m == 0:
            env.stats.footnote_split_lines += len(flat)
            return groups
        # placed prefix
        placed: list[tuple[FnGroup, int]] = []
        for gi, li, _ in flat[:m]:
            if placed and placed[-1][0] is groups[gi]:
                placed[-1] = (groups[gi], li + 1)
            else:
                placed.append((groups[gi], li + 1))
        h_fn = flat[m - 1][2]
        rule_top = s.body_bottom - h_fn - s.footnote_space_after - s.footnote_rule_thickness
        stack_top = rule_top + s.footnote_rule_thickness + s.footnote_space_after
        out = page.items
        out.append(rule_item("footnote", s.body_x, rule_top, s.footnote_rule_width,
                             s.footnote_rule_thickness))
        face = env.face(s.footnote_font)
        place = self.new_stack()
        for g, count in placed:
            place.start_group()
            for k in range(count):
                line = g.lines[k]
                base = stack_top + place.add_line(line)
                for r in line.runs:
                    out.append(text_item("footnote", r.face, r.size, r.x, base - r.raise_,
                                         r.width, r.text))
                env.stats.lines += 1
                if k == 0 and g.marked:
                    text = str(g.fn.number)
                    w = face.width(text, s.footnote_mark_size)
                    x = s.body_x + s.footnote_indent - s.footnote_mark_gap - w
                    out.append(text_item("footnote", face.name, s.footnote_mark_size, x,
                                         base - s.footnote_mark_raise, w, text))
        carry: list[FnGroup] = []
        last_g, last_count = placed[-1]
        if last_count < len(last_g.lines):
            carry.append(FnGroup(last_g.fn, last_g.lines[last_count:], False))
        gi_last = groups.index(last_g)
        carry.extend(groups[gi_last + 1:])
        env.stats.footnote_split_lines += sum(len(g.lines) for g in carry)
        return carry
