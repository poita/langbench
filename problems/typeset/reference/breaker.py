"""Total-fit line breaking and the setting of one line."""

from hlist import Box, Glue, Penalty
from metrics import fdiv, scale

TIGHT, DECENT, LOOSE, VERY_LOOSE = 0, 1, 2, 3


def evaluate(w, y, z, infinite, measure):
    """(badness, fitness, usable) of a line of natural width w."""
    d = measure - w
    if d >= 0 and infinite:
        return 0, DECENT, True
    if d == 0:
        return 0, DECENT, True
    if d > 0:
        if y == 0:
            return 10000, VERY_LOOSE, False
        badness = min(10000, fdiv(100 * d * d * d, y * y * y))
        if d > y:
            fitness = VERY_LOOSE
        elif 2 * d > y:
            fitness = LOOSE
        else:
            fitness = DECENT
        return badness, fitness, True
    e = -d
    if z == 0 or e > z:
        return 10000, TIGHT, False
    badness = min(10000, fdiv(100 * e * e * e, z * z * z))
    fitness = TIGHT if 2 * e > z else DECENT
    return badness, fitness, True


class Node:
    __slots__ = ("bp", "cls", "total", "prev", "flagged")

    def __init__(self, bp, cls, total, prev, flagged):
        self.bp = bp
        self.cls = cls
        self.total = total
        self.prev = prev
        self.flagged = flagged


class Breaker:
    def __init__(self, settings):
        self.settings = settings

    def demerits(self, badness, penalty, flagged, cls, cls0, flagged0, is_final):
        settings = self.settings
        base = settings["line-penalty"] + badness
        dem = base * base
        if 0 <= penalty < 10000:
            dem += penalty * penalty
        elif -10000 < penalty < 0:
            dem -= penalty * penalty
        if flagged and flagged0:
            dem += settings["double-hyphen-demerits"]
        if abs(cls - cls0) > 1:
            dem += settings["adj-demerits"]
        if is_final and flagged0:
            dem += settings["final-hyphen-demerits"]
        return dem

    def run(self, hl, everything):
        """One pass of the node table; returns the nodes or None on failure."""
        settings = self.settings
        tolerance = settings["tolerance"]
        measure = hl.ctx.measure
        first = measure - hl.ctx.first_indent
        nodes = [Node(0, DECENT, 0, None, False)]
        active = [0]
        buckets = {}
        breaks = hl.breaks
        final_bp = breaks[-1]
        cum_w, cum_y, cum_z, cum_inf = hl.cum_w, hl.cum_y, hl.cum_z, hl.cum_inf
        for b in breaks[1:]:
            is_final = b == final_bp
            penalty = hl.break_penalty(b)
            flagged = hl.break_flagged(b)
            pre = hl.items[b].pre if isinstance(hl.items[b], Penalty) else None
            pre_width = pre.width if pre is not None else 0
            best = {}
            survivors = []
            for ni in active:
                node = nodes[ni]
                limit = first if node.bp == 0 else measure
                start = hl.line_start(node.bp)
                if start > b:
                    start = b
                w0 = cum_w[b] - cum_w[start]
                y = cum_y[b] - cum_y[start]
                z = cum_z[b] - cum_z[start]
                infinite = cum_inf[b] - cum_inf[start] > 0
                if w0 - z > limit:
                    key = (node.flagged, node.cls)
                    candidate = (node.total, ni)
                    current = buckets.get(key)
                    if current is None or candidate < current:
                        buckets[key] = candidate
                    continue
                survivors.append(ni)
                badness, fitness, usable = evaluate(w0 + pre_width, y, z, infinite, limit)
                if not everything and (not usable or badness > tolerance):
                    continue
                total = node.total + self.demerits(
                    badness, penalty, flagged, fitness, node.cls, node.flagged, is_final)
                candidate = (total, ni)
                current = best.get(fitness)
                if current is None or candidate < current:
                    best[fitness] = candidate
            active = survivors
            if everything:
                for (flagged0, cls0), (total0, ni) in buckets.items():
                    total = total0 + self.demerits(
                        10000, penalty, flagged, TIGHT, cls0, flagged0, is_final)
                    candidate = (total, ni)
                    current = best.get(TIGHT)
                    if current is None or candidate < current:
                        best[TIGHT] = candidate
            for fitness in sorted(best):
                total, pred = best[fitness]
                active.append(len(nodes))
                nodes.append(Node(b, fitness, total, pred, flagged))
        chosen = None
        for index, node in enumerate(nodes):
            if node.bp != final_bp:
                continue
            key = (node.total, node.cls, index)
            if chosen is None or key < chosen[0]:
                chosen = (key, index)
        if chosen is None:
            return None, 0
        path = []
        index = chosen[1]
        total = nodes[index].total
        while nodes[index].prev is not None:
            path.append((nodes[nodes[index].prev].bp, nodes[index].bp))
            index = nodes[index].prev
        path.reverse()
        return path, total

    def break_list(self, hl):
        """Break a list; returns (lines, total demerits, needed pass 2)."""
        path, total = self.run(hl, False)
        if path is not None:
            return path, total, False
        path, total = self.run(hl, True)
        return path, total, True


class Run:
    """One placed text run of a line."""

    __slots__ = ("face", "size", "raise_", "text", "x", "width", "mark")

    def __init__(self, face, size, raise_, text, x, width, mark):
        self.face = face
        self.size = size
        self.raise_ = raise_
        self.text = text
        self.x = x
        self.width = width
        self.mark = mark


class SetLine:
    """The result of setting one line: its runs and its vertical metrics."""

    __slots__ = ("runs", "ascent", "depth", "overfull", "hyphenated", "marks",
                 "width", "end_x")

    def __init__(self):
        self.runs = []
        self.ascent = 0
        self.depth = 0
        self.overfull = False
        self.hyphenated = False
        self.marks = []
        self.width = 0
        self.end_x = 0


def distribute(total, weights):
    """Spread `total` over glues in proportion to `weights`, summing exactly."""
    sum_weights = sum(weights)
    out = []
    prefix = 0
    previous = 0
    for weight in weights:
        prefix += weight
        current = fdiv(total * prefix, sum_weights)
        out.append(current - previous)
        previous = current
    return out


def set_line(hl, a, b, metrics):
    """Place the line between breakpoints a and b."""
    items = hl.items
    start = hl.line_start(a)
    if start > b:
        start = b
    line_items = list(items[start:b])
    tail = items[b] if b < len(items) else None
    if isinstance(tail, Penalty) and tail.pre is not None:
        line_items.append(tail.pre)
    ctx = hl.ctx
    first = a == 0
    measure = ctx.measure - ctx.first_indent if first else ctx.measure
    left = ctx.left + ctx.first_indent if first else ctx.left

    natural = 0
    glues = []
    infinite = None
    for item in line_items:
        if isinstance(item, Box):
            natural += item.width
        elif isinstance(item, Glue):
            natural += item.w
            if item.infinite:
                infinite = item
            else:
                glues.append(item)
    widths = {}
    if infinite is not None:
        for glue in glues:
            widths[id(glue)] = glue.w
        widths[id(infinite)] = 0
    elif ctx.align != "justify":
        for glue in glues:
            widths[id(glue)] = glue.w
    else:
        excess = measure - natural
        stretch = sum(glue.y for glue in glues)
        shrink = sum(glue.z for glue in glues)
        if excess == 0 or (excess > 0 and stretch == 0) or (excess < 0 and shrink == 0):
            for glue in glues:
                widths[id(glue)] = glue.w
        elif excess > 0:
            for glue, delta in zip(glues, distribute(excess, [g.y for g in glues])):
                widths[id(glue)] = glue.w + delta
        elif -excess <= shrink:
            for glue, delta in zip(glues, distribute(excess, [g.z for g in glues])):
                widths[id(glue)] = glue.w + delta
        else:
            for glue in glues:
                widths[id(glue)] = glue.w - glue.z

    set_width = 0
    for item in line_items:
        if isinstance(item, Box):
            set_width += item.width
        elif isinstance(item, Glue):
            set_width += widths[id(item)]

    result = SetLine()
    result.width = set_width
    if ctx.align == "right":
        x = left + measure - set_width
    elif ctx.align == "center":
        x = left + fdiv(measure - set_width, 2)
    else:
        x = left

    ascent = 0
    depth = 0
    has_text = False
    pending_run = None
    pending_box = None
    for item in line_items:
        if isinstance(item, Box):
            if item.face is None:
                x += item.width
                pending_run = pending_box = None
                continue
            has_text = True
            face = metrics.face(item.face)
            ascent = max(ascent, scale(face.ascent, item.size) + item.raise_)
            depth = max(depth, max(0, scale(face.descent, item.size) - item.raise_))
            if item.mark is not None:
                result.marks.append(item.mark)
            if (pending_box is not None
                    and (pending_box.face, pending_box.size, pending_box.raise_) ==
                    (item.face, item.size, item.raise_)
                    and pending_box.frag == item.frag):
                pending_run.text += item.text
                pending_run.width += item.width
                x += item.width
                continue
            run = Run(item.face, item.size, item.raise_, item.text, x,
                      item.width, item.mark)
            result.runs.append(run)
            pending_run = run
            pending_box = item
            x += item.width
        elif isinstance(item, Glue):
            x += widths[id(item)]
            pending_run = pending_box = None
        else:
            continue
    if not has_text:
        face = metrics.face(ctx.base_face())
        ascent = scale(face.ascent, ctx.size)
        depth = scale(face.descent, ctx.size)
    result.end_x = x
    result.ascent = ascent
    result.depth = depth
    result.overfull = set_width > measure
    result.hyphenated = isinstance(tail, Penalty) and tail.pre is not None
    return result
