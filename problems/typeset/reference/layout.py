"""Vertical lists, tables, footnotes, floats, pagination and output items."""

from collections import deque

from metrics import Metrics, fdiv, scale, face_name, roman, alpha_label
from hlist import Builder, Context, HList, Box, Glue, Penalty
from breaker import Breaker, set_line
from cdx import literal_units

REGION_RANK = {"header": 0, "float": 1, "body": 2, "footnote": 3, "footer": 4}
KIND_RANK = {"text": 0, "rule": 1, "box": 2}


class VLine:
    """One placed line of a horizontal list, with its group identity."""

    __slots__ = ("line", "leading", "gid", "k", "n", "kind", "footnotes",
                 "extras", "heading")

    def __init__(self, line, leading, gid, k, n, kind):
        self.line = line
        self.leading = leading
        self.gid = gid
        self.k = k
        self.n = n
        self.kind = kind
        self.footnotes = list(line.marks)
        self.extras = []
        self.heading = None


class VGlue:
    __slots__ = ("height",)

    def __init__(self, height):
        self.height = height


class VRule:
    __slots__ = ("x", "width", "thickness")

    def __init__(self, x, width, thickness):
        self.x = x
        self.width = width
        self.thickness = thickness


class VRow:
    __slots__ = ("cells", "ascent", "leading", "height")

    def __init__(self, cells, ascent, leading, height):
        self.cells = cells
        self.ascent = ascent
        self.leading = leading
        self.height = height


class VFloatMark:
    __slots__ = ("figure",)

    def __init__(self, figure):
        self.figure = figure


class VForceBreak:
    __slots__ = ()


class FigureBlock:
    """A laid-out figure: its frame, its caption lines and its total height."""

    __slots__ = ("number", "fx", "fw", "fh", "frame", "caption", "height")

    def __init__(self, number):
        self.number = number
        self.frame = False
        self.caption = []
        self.height = 0


class FootnoteBlock:
    __slots__ = ("number", "lines")

    def __init__(self, number, lines):
        self.number = number
        self.lines = lines


class Page:
    def __init__(self, label):
        self.label = label
        self.number = 0
        self.items = []

    def text(self, region, face, size, x, y, width, string):
        quoted = string.replace("\\", "\\\\").replace('"', '\\"')
        line = '  text %s %s %d %d %d %d "%s"' % (region, face, size, x, y, width, quoted)
        self.items.append((REGION_RANK[region], y, x, KIND_RANK["text"], line))

    def rule(self, region, x, y, width, thickness):
        line = "  rule %s %d %d %d %d" % (region, x, y, width, thickness)
        self.items.append((REGION_RANK[region], y, x, KIND_RANK["rule"], line))

    def box(self, region, x, y, width, height):
        line = "  box %s %d %d %d %d" % (region, x, y, width, height)
        self.items.append((REGION_RANK[region], y, x, KIND_RANK["box"], line))

    def sorted_lines(self):
        return [entry[4] for entry in sorted(self.items)]


class Placer:
    """Walks vertical items keeping the cursor and baseline state."""

    def __init__(self, top, line_skip):
        self.top = top
        self.line_skip = line_skip
        self.cursor = top
        self.fresh = True
        self.prev_baseline = 0
        self.prev_depth = 0
        self.used = 0

    def baseline(self, vline):
        if self.fresh:
            return self.cursor + vline.line.ascent
        return self.prev_baseline + max(
            vline.leading, self.prev_depth + self.line_skip + vline.line.ascent)

    def advance_line(self, vline, baseline):
        self.cursor = baseline + vline.line.depth
        self.prev_baseline = baseline
        self.prev_depth = vline.line.depth
        self.fresh = False
        self.used = self.cursor - self.top

    def advance_block(self, height):
        self.cursor += height
        self.fresh = True
        self.used = self.cursor - self.top

    def advance_glue(self, height):
        self.cursor += height
        self.fresh = True

    def advance_mark(self):
        # Only trailing GLUE is dropped from the used height, so glue before
        # a FLOATMARK counts once the mark has been passed.
        self.used = self.cursor - self.top


class Engine:
    def __init__(self, settings, doc):
        self.settings = settings
        self.doc = doc
        self.metrics = Metrics("data")
        self.breaker = Breaker(settings)
        self.gid = 0
        self.report = {
            "lines": 0,
            "footnote-split-lines": 0,
            "hyphenated-lines": 0,
            "overfull-lines": 0,
            "emergency-lists": 0,
            "total-demerits": 0,
        }
        self.footnote_blocks = {}
        self.figure_blocks = {}
        self.headings = []
        self.counters = [0, 0, 0, 0]

    def bump_heading(self, level):
        """Advance the heading counters and return the new number string."""
        self.counters[level - 1] += 1
        for index in range(level, 4):
            self.counters[index] = 0
        return ".".join(str(self.counters[i]) for i in range(level))

    def footnote_context(self):
        settings = self.settings
        return Context(
            family=settings["footnote-font"], bold=False, italic=False,
            size=settings["footnote-size"], leading=settings["footnote-leading"],
            left=settings.body_x + settings["footnote-indent"],
            measure=self.clamp(settings.body_width - settings["footnote-indent"]),
            first_indent=0, align=settings["align"],
            hyphenate=settings["hyphenate"],
        )

    def build_footnotes(self):
        """Break every footnote once, in source order."""
        ctx = self.footnote_context()
        for note in self.doc.footnotes:
            builder = self.builder(ctx)
            hl = builder.build(builder.resolve(note.units))
            self.footnote_blocks[note.number] = FootnoteBlock(
                note.number, self.break_hlist(hl))

    def build_figures(self):
        for node in self.doc.figures:
            self.figure_block(node)

    def figure_block(self, node):
        """Lay out one figure block relative to its own top edge."""
        cached = self.figure_blocks.get(node.index)
        if cached is not None:
            return cached
        settings = self.settings
        width = node.width if node.width is not None else settings["figure-width"]
        fw = width if width > 0 else settings.body_width
        fx = settings.body_x + fdiv(settings.body_width - fw, 2)
        block = FigureBlock(node.index)
        block.fx = fx
        block.fw = fw
        block.fh = node.height
        block.frame = settings["figure-frame"]
        ctx = Context(
            family=settings["figure-caption-font"], bold=False, italic=False,
            size=settings["figure-caption-size"],
            leading=settings["figure-caption-leading"],
            left=fx, measure=self.clamp(fw), first_indent=0,
            align=settings["figure-caption-align"], hyphenate=settings["hyphenate"],
        )
        builder = self.builder(ctx)
        resolved = []
        prefix = settings.text("figure-caption-prefix")
        if prefix:
            resolved.extend(builder.resolve(literal_units(prefix)))
            face = self.face(ctx.base_face())
            size = ctx.size
            resolved.append(("glue", scale(face.space, size),
                             scale(face.stretch, size), scale(face.shrink, size)))
        resolved.extend(builder.resolve(literal_units("%d." % node.index)))
        resolved.append(("rig", settings["figure-caption-gap"]))
        resolved.extend(builder.resolve(node.units))
        hl = builder.build(resolved)
        lines = self.break_hlist(hl)
        cursor = node.height + settings["figure-caption-space"]
        fresh = True
        prev_baseline = 0
        prev_depth = 0
        for line in lines:
            if fresh:
                baseline = cursor + line.ascent
            else:
                baseline = prev_baseline + max(
                    ctx.leading, prev_depth + settings["line-skip"] + line.ascent)
            block.caption.append((line, baseline))
            cursor = baseline + line.depth
            prev_baseline = baseline
            prev_depth = line.depth
            fresh = False
        block.height = cursor
        self.figure_blocks[node.index] = block
        return block

    def patterns(self):
        return self.metrics.patterns(self.settings["hyphen-patterns"])

    def face(self, name):
        return self.metrics.face(name)

    def new_gid(self):
        self.gid += 1
        return self.gid

    # -- breaking one horizontal list ------------------------------------

    def break_hlist(self, hl):
        """Break a list and return its set lines, updating the counters."""
        path, total, emergency = self.breaker.break_list(hl)
        self.report["total-demerits"] += total
        if emergency:
            self.report["emergency-lists"] += 1
        lines = []
        for a, b in path:
            line = set_line(hl, a, b, self.metrics)
            if line.hyphenated:
                self.report["hyphenated-lines"] += 1
            if line.overfull:
                self.report["overfull-lines"] += 1
            lines.append(line)
        return lines

    def set_single(self, hl):
        """Set an unbroken list (a @pre line or a header slot) as one line."""
        line = set_line(hl, hl.breaks[0], hl.breaks[-1], self.metrics)
        return line

    # -- root context ----------------------------------------------------

    def root_context(self):
        settings = self.settings
        return Context(
            family=settings["body-font"], bold=False, italic=False,
            size=settings["body-size"], leading=settings["leading"],
            left=settings.body_x, measure=settings.body_width,
            first_indent=0, align=settings["align"],
            hyphenate=settings["hyphenate"],
        )

    def builder(self, ctx):
        return Builder(self, ctx)

    def clamp(self, measure):
        return measure if measure >= 1000 else 1000


class VerticalBuilder:
    """Turns the block tree into one flat list of vertical items."""

    def __init__(self, engine):
        self.engine = engine
        self.settings = engine.settings
        self.items = []
        self.pending_max = 0
        self.pending_add = 0
        self.started = False

    def enter(self, space_before):
        self.pending_max = max(self.pending_max, space_before)

    def leave(self, space_after):
        self.pending_max = max(self.pending_max, space_after)

    def leaf_space(self, space_before, space_after):
        self.pending_max = max(self.pending_max, space_before)
        if self.started and self.pending_max + self.pending_add > 0:
            self.items.append(VGlue(self.pending_max + self.pending_add))
        self.pending_max = space_after
        self.pending_add = 0

    def emit_lines(self, lines, leading, kind, marker=None, heading=None):
        """Append one group of lines; the marker and heading ride on line 1."""
        gid = self.engine.new_gid()
        total = len(lines)
        out = []
        for index, line in enumerate(lines):
            vline = VLine(line, leading, gid, index + 1, total, kind)
            if index == 0:
                if marker is not None:
                    vline.extras.append(marker)
                vline.heading = heading
            self.items.append(vline)
            out.append(vline)
        self.started = True
        return out

    # -- the walk ---------------------------------------------------------

    def walk(self, nodes, ctx, list_depth):
        settings = self.settings
        for node in nodes:
            kind = node.kind
            if kind == "para":
                self.paragraph(node, ctx)
            elif kind == "heading":
                self.heading(node, ctx)
            elif kind == "quote":
                self.enter(settings["quote-space"])
                inner = ctx.clone(
                    left=ctx.left + settings["quote-indent"],
                    measure=self.engine.clamp(ctx.measure - 2 * settings["quote-indent"]),
                )
                self.walk(node.children, inner, list_depth)
                self.leave(settings["quote-space"])
            elif kind == "group":
                inner = self.group_context(node, ctx)
                self.walk(node.children, inner, list_depth)
            elif kind == "list":
                self.enter(settings["list-space"])
                inner = ctx.clone(
                    left=ctx.left + settings["list-indent"],
                    measure=self.engine.clamp(ctx.measure - settings["list-indent"]),
                )
                for index, item in enumerate(node.children):
                    if index > 0:
                        self.pending_max = max(self.pending_max, settings["list-item-space"])
                    self.item(item, node, inner, list_depth + 1)
                self.leave(settings["list-space"])
            elif kind == "table":
                self.table(node, ctx)
            elif kind == "pre":
                self.pre(node, ctx)
            elif kind == "rule":
                self.leaf_space(settings["rule-space"], settings["rule-space"])
                self.items.append(VRule(ctx.left, ctx.measure, settings["rule-thickness"]))
                self.started = True
            elif kind == "figure":
                self.leaf_space(0, 0)
                self.items.append(VFloatMark(node))
                self.started = True
            elif kind == "vspace":
                self.pending_add += node.height
            elif kind == "newpage":
                self.items.append(VForceBreak())
                self.pending_max = 0
                self.pending_add = 0

    def group_context(self, node, ctx):
        changes = {}
        if node.align is not None:
            changes["align"] = node.align
        if node.size is not None:
            changes["size"] = node.size
        if node.leading is not None:
            changes["leading"] = node.leading
        if node.font is not None:
            changes["family"] = node.font
        indent = node.indent or 0
        right = node.right_indent or 0
        changes["left"] = ctx.left + indent
        changes["measure"] = self.engine.clamp(ctx.measure - indent - right)
        return ctx.clone(**changes)

    def paragraph(self, node, ctx):
        settings = self.settings
        self.leaf_space(settings["par-space"], settings["par-space"])
        inner = ctx.clone(first_indent=settings["par-indent"])
        builder = self.engine.builder(inner)
        hl = builder.build(builder.resolve(node.units))
        lines = self.engine.break_hlist(hl)
        self.emit_lines(lines, inner.leading, "other")

    def heading(self, node, ctx):
        settings = self.settings
        level = node.level
        numbered = (not node.starred) and settings["heading-number"]
        if settings["h1-newpage"] and level == 1:
            self.items.append(VForceBreak())
            self.pending_max = 0
            self.pending_add = 0
        self.leaf_space(settings["h%d-space-before" % level],
                        settings["h%d-space-after" % level])
        number = ""
        if numbered:
            number = self.engine.bump_heading(level)
        inner = ctx.clone(
            family=settings["heading-font"], bold=settings["heading-bold"],
            italic=settings["heading-italic"], size=settings["h%d-size" % level],
            leading=settings["h%d-leading" % level], align=settings["heading-align"],
            first_indent=0,
        )
        builder = self.engine.builder(inner)
        resolved = []
        if number:
            resolved.extend(builder.resolve(literal_units(number)))
            resolved.append(("rig", settings["heading-number-gap"]))
        resolved.extend(builder.resolve(node.units))
        hl = builder.build(resolved)
        lines = self.engine.break_hlist(hl)
        record = {"level": level, "number": number, "plain": node.plain,
                  "starred": node.starred, "page": None}
        self.engine.headings.append(record)
        self.emit_lines(lines, inner.leading, "heading", heading=record)

    def item(self, node, list_node, ctx, depth):
        settings = self.settings
        self.leaf_space(0, 0)
        inner = ctx.clone(first_indent=0)
        builder = self.engine.builder(inner)
        hl = builder.build(builder.resolve(node.units))
        lines = self.engine.break_hlist(hl)
        marker = self.marker_run(node, list_node, ctx, depth)
        self.emit_lines(lines, inner.leading, "other", marker=marker)
        self.walk(node.children, ctx, depth)

    def marker_run(self, node, list_node, ctx, depth):
        settings = self.settings
        bucket = depth % 3
        if list_node.ordered:
            if bucket == 1:
                text = "%d." % node.number
            elif bucket == 2:
                text = alpha_label(node.number) + "."
            else:
                text = roman(node.number) + "."
        else:
            text = {1: "•", 2: "–", 0: "*"}[bucket]
        face = face_name(ctx.family, False, False)
        width = self.engine.face(face).text_width(text, ctx.size)
        x = ctx.left - settings["list-marker-gap"] - width
        return (face, ctx.size, x, width, text)

    def pre(self, node, ctx):
        settings = self.settings
        self.leaf_space(settings["pre-space"], settings["pre-space"])
        face = face_name(settings["pre-font"], False, False)
        size = settings["pre-size"]
        inner = ctx.clone(
            family=settings["pre-font"], bold=False, italic=False, size=size,
            leading=settings["pre-leading"], align="left", first_indent=0,
            left=ctx.left + settings["pre-indent"],
            measure=self.engine.clamp(ctx.measure - settings["pre-indent"]),
        )
        lines = []
        for index, text in enumerate(node.lines):
            items = []
            if text:
                width = self.engine.face(face).text_width(text, size)
                items.append(Box(face, size, 0, text, width, index + 1))
            items.append(Penalty(10000, False))
            items.append(Glue(0, 0, 0, True))
            items.append(Penalty(-10000, False))
            hl = HList(items, inner)
            line = self.engine.set_single(hl)
            if line.overfull:
                self.engine.report["overfull-lines"] += 1
            lines.append(line)
        self.emit_lines(lines, inner.leading, "other")

    def table(self, node, ctx):
        settings = self.settings
        self.leaf_space(settings["table-space"], settings["table-space"])
        cols = node.cols
        rows = [element for element in node.elements if element.kind == "row"]
        cell_lists = []
        for row in rows:
            built = []
            for index, units in enumerate(row.cells):
                cell_ctx = self.cell_context(ctx, node.align[index], 0, 1000)
                builder = self.engine.builder(cell_ctx)
                built.append(builder.build(builder.resolve(units)))
            cell_lists.append(built)
        nat = [0] * cols
        minimum = [0] * cols
        for built in cell_lists:
            for index, hl in enumerate(built):
                nat[index] = max(nat[index], hl.natural_width())
                minimum[index] = max(minimum[index], hl.min_width())
        gap = settings["table-col-gap"]
        avail = max(0, ctx.measure - (cols - 1) * gap)
        if sum(nat) <= avail:
            widths = list(nat)
        elif sum(minimum) >= avail:
            widths = list(minimum)
        else:
            deficit = sum(nat) - avail
            span = sum(nat[i] - minimum[i] for i in range(cols))
            widths = []
            prefix = 0
            previous = 0
            for i in range(cols):
                prefix += nat[i] - minimum[i]
                current = fdiv(deficit * prefix, span)
                widths.append(nat[i] - (current - previous))
                previous = current
        total_width = sum(widths) + (cols - 1) * gap
        xs = []
        x = ctx.left
        for i in range(cols):
            xs.append(x)
            x += widths[i] + gap

        row_items = {}
        for row_index, built in enumerate(cell_lists):
            cells = []
            for index, hl in enumerate(built):
                hl.ctx = self.cell_context(ctx, node.align[index], xs[index], widths[index])
                cells.append(self.engine.break_hlist(hl))
            ascent = max(cell[0].ascent for cell in cells)
            count = max(len(cell) for cell in cells)
            depth = max(cell[-1].depth for cell in cells)
            leading = settings["table-leading"]
            height = ascent + (count - 1) * leading + depth
            row_items[id(rows[row_index])] = VRow(cells, ascent, leading, height)

        elements = node.elements
        previous_kind = None
        for index, element in enumerate(elements):
            if element.kind == "row":
                if previous_kind == "row":
                    self.items.append(VGlue(settings["table-row-space"]))
                self.items.append(row_items[id(element)])
            else:
                if index > 0:
                    self.items.append(VGlue(settings["table-rule-space"]))
                self.items.append(VRule(ctx.left, total_width,
                                        settings["table-rule-thickness"]))
                if index < len(elements) - 1:
                    self.items.append(VGlue(settings["table-rule-space"]))
            previous_kind = element.kind
        self.started = True

    def cell_context(self, ctx, letter, left, measure):
        align = {"l": "left", "r": "right", "c": "center"}[letter]
        return ctx.clone(
            bold=False, italic=False, leading=self.settings["table-leading"],
            align=align, first_indent=0, left=left, measure=measure,
        )


class Legality:
    """Precomputed page-break legality for one vertical item list."""

    def __init__(self, engine, items):
        self.settings = engine.settings
        self.items = items
        self.n = len(items)
        self.forbidden = set()
        if self.settings["keep-with-next"]:
            self.build_keep_runs()

    def build_keep_runs(self):
        items = self.items
        n = self.n
        orphans = self.settings["orphans"]
        index = 0
        while index < n:
            item = items[index]
            if not (isinstance(item, VLine) and item.kind == "heading" and item.k == 1):
                index += 1
                continue
            last = index
            while last + 1 < n and isinstance(items[last + 1], VLine) \
                    and items[last + 1].gid == item.gid:
                last += 1
            for position in range(index + 1, last + 1):
                self.forbidden.add(position)
            cursor = last + 1
            while cursor < n and isinstance(items[cursor], (VGlue, VFloatMark)):
                self.forbidden.add(cursor)
                cursor += 1
            if cursor < n:
                self.forbidden.add(cursor)
                target = items[cursor]
                if isinstance(target, VLine):
                    extra = min(orphans, target.n) - 1
                    probe = cursor + 1
                    taken = 0
                    while probe < n and taken < extra:
                        candidate = items[probe]
                        if isinstance(candidate, VLine) and candidate.gid == target.gid:
                            self.forbidden.add(probe)
                            taken += 1
                            probe += 1
                        else:
                            break
            index = last + 1

    def legal(self, j):
        if j <= 0:
            return False
        if j >= self.n:
            return True
        item = self.items[j]
        if isinstance(item, VLine):
            if item.kind == "heading":
                if item.k != 1:
                    return False
            elif item.k > 1:
                if item.k - 1 < self.settings["orphans"]:
                    return False
                if item.n - item.k + 1 < self.settings["widows"]:
                    return False
        if j in self.forbidden:
            return False
        return True


class FootStack:
    """The running height of a page's footnote stack as groups are appended."""

    def __init__(self, engine):
        settings = engine.settings
        self.item_space = settings["footnote-item-space"]
        self.leading = settings["footnote-leading"]
        self.line_skip = settings["line-skip"]
        self.cursor = 0
        self.fresh = True
        self.prev_baseline = 0
        self.prev_depth = 0
        self.started = False
        self.overhead = (settings["footnote-space-before"]
                         + settings["footnote-rule-thickness"]
                         + settings["footnote-space-after"])

    def add(self, lines):
        for index, line in enumerate(lines):
            if index == 0 and self.started:
                self.cursor += self.item_space
                self.fresh = True
            self.started = True
            if self.fresh:
                baseline = self.cursor + line.ascent
            else:
                baseline = self.prev_baseline + max(
                    self.leading, self.prev_depth + self.line_skip + line.ascent)
            self.cursor = baseline + line.depth
            self.prev_baseline = baseline
            self.prev_depth = line.depth
            self.fresh = False
            yield baseline

    def consume(self, lines):
        for _ in self.add(lines):
            pass

    def area(self):
        return 0 if not self.started else self.overhead + self.cursor


class Paginator:
    """Produces pages from one vertical item list."""

    def __init__(self, engine, items, floats_on, footnotes_on):
        self.engine = engine
        self.settings = engine.settings
        self.items = items
        self.floats_on = floats_on
        self.footnotes_on = footnotes_on
        self.legality = Legality(engine, items)
        self.queue = deque()
        self.carried = []

    def run(self):
        settings = self.settings
        items = self.items
        n = len(items)
        pages = []
        i = 0
        while True:
            while i < n and isinstance(items[i], (VGlue, VForceBreak)):
                i += 1
            if i >= n and not self.queue and not self.carried:
                break
            page = Page(None)
            has_body = i < n
            taken, zone = self.take_floats(has_body)
            body_top = settings.body_y + zone
            goal = settings.body_height - zone
            cut = self.choose_cut(i, goal) if has_body else i
            body = list(items[i:cut])
            while body and isinstance(body[-1], VGlue):
                body.pop()
            y = settings.body_y
            for block in taken:
                self.emit_figure(page, block, y)
                y += block.height + settings["float-space-after"]
            used = self.place_body(page, body, body_top, len(pages))
            if self.footnotes_on:
                self.place_footnotes(page, body, goal, used, bool(body))
            if self.floats_on:
                for item in body:
                    if isinstance(item, VFloatMark):
                        self.queue.append(self.engine.figure_block(item.figure))
            pages.append(page)
            i = cut
        return pages

    # -- floats -----------------------------------------------------------

    def take_floats(self, has_body):
        if not self.floats_on or not self.queue:
            return [], 0
        settings = self.settings
        after = settings["float-space-after"]
        taken = []
        total = 0
        while self.queue:
            block = self.queue[0]
            count = len(taken) + 1
            zone_next = total + block.height + count * after
            if has_body:
                ok = settings.body_height - zone_next >= settings["float-min-body"]
            else:
                ok = count == 1 or zone_next <= settings.body_height
            if not ok:
                break
            taken.append(block)
            total += block.height
            self.queue.popleft()
        return taken, total + len(taken) * after

    def emit_figure(self, page, block, y):
        if block.frame:
            page.box("float", block.fx, y, block.fw, block.fh)
        for line, baseline in block.caption:
            self.emit_runs(page, "float", line, y + baseline)
            self.engine.report["lines"] += 1

    # -- choosing the cut --------------------------------------------------

    def choose_cut(self, i, goal):
        items = self.items
        n = len(items)
        settings = self.settings
        cap = settings["footnote-max-height"]
        placer = Placer(0, settings["line-skip"])
        stack = FootStack(self.engine)
        for lines, _mark in self.carried:
            stack.consume(lines)
        best = None
        first_legal = None
        j = i
        while j < n:
            j += 1
            if isinstance(items[j - 1], VForceBreak):
                return j - 1
            self.advance(placer, items[j - 1])
            if self.footnotes_on and isinstance(items[j - 1], VLine):
                for number in items[j - 1].footnotes:
                    stack.consume(self.engine.footnote_blocks[number].lines)
            used = placer.used
            if self.footnotes_on:
                used += min(stack.area(), cap)
            legal = self.legality.legal(j)
            if legal and first_legal is None:
                first_legal = j
            if used <= goal and legal:
                best = j
            if used > goal:
                break
        if best is not None:
            return best
        if first_legal is not None:
            return first_legal
        while j < n:
            j += 1
            if self.legality.legal(j):
                return j
        return n

    @staticmethod
    def advance(placer, item):
        if isinstance(item, VLine):
            placer.advance_line(item, placer.baseline(item))
        elif isinstance(item, VGlue):
            placer.advance_glue(item.height)
        elif isinstance(item, VRule):
            placer.advance_block(item.thickness)
        elif isinstance(item, VRow):
            placer.advance_block(item.height)
        elif isinstance(item, VFloatMark):
            placer.advance_mark()

    # -- placing the body --------------------------------------------------

    def place_body(self, page, body, body_top, page_index):
        settings = self.settings
        engine = self.engine
        placer = Placer(body_top, settings["line-skip"])
        for item in body:
            if isinstance(item, VLine):
                baseline = placer.baseline(item)
                self.emit_runs(page, "body", item.line, baseline)
                for face, size, x, width, text in item.extras:
                    page.text("body", face, size, x, baseline, width, text)
                if item.heading is not None and item.heading["page"] is None:
                    item.heading["page"] = page_index
                placer.advance_line(item, baseline)
                engine.report["lines"] += 1
            elif isinstance(item, VGlue):
                placer.advance_glue(item.height)
            elif isinstance(item, VRule):
                page.rule("body", item.x, placer.cursor, item.width, item.thickness)
                placer.advance_block(item.thickness)
            elif isinstance(item, VRow):
                top = placer.cursor
                for cell in item.cells:
                    for index, line in enumerate(cell):
                        baseline = top + item.ascent + index * item.leading
                        self.emit_runs(page, "body", line, baseline)
                        engine.report["lines"] += 1
                placer.advance_block(item.height)
            elif isinstance(item, VFloatMark):
                placer.advance_mark()
        return placer.used

    @staticmethod
    def emit_runs(page, region, line, baseline):
        for run in line.runs:
            if not run.text:
                continue
            page.text(region, run.face, run.size, run.x, baseline - run.raise_,
                      run.width, run.text)

    # -- footnotes ---------------------------------------------------------

    def place_footnotes(self, page, body, goal, used, body_nonempty):
        settings = self.settings
        engine = self.engine
        groups = list(self.carried)
        for item in body:
            if isinstance(item, VLine):
                for number in item.footnotes:
                    block = engine.footnote_blocks[number]
                    groups.append((block.lines, number))
        if not groups:
            self.carried = []
            return
        flat = []
        bounds = []
        for lines, mark in groups:
            bounds.append((len(flat), len(flat) + len(lines), mark))
            flat.extend(lines)
        heights = self.stack_heights(groups)
        avail = (goal - used - settings["footnote-space-before"]
                 - settings["footnote-rule-thickness"] - settings["footnote-space-after"])
        count = 0
        while count + 1 <= len(flat) and heights[count + 1] <= avail:
            count += 1
        if 0 < count < len(flat):
            for start, stop, _mark in bounds:
                if start < count < stop:
                    if count - start < settings["footnote-min-split"] and start > 0:
                        count = start
                    break
        if not body_nonempty and count == 0:
            count = 1
        if count == 0:
            engine.report["footnote-split-lines"] += len(flat)
            self.carried = groups
            return
        placed = []
        remaining = []
        for start, stop, mark in bounds:
            if stop <= count:
                placed.append((flat[start:stop], mark))
            elif start >= count:
                remaining.append((flat[start:stop], mark))
            else:
                placed.append((flat[start:count], mark))
                remaining.append((flat[count:stop], None))
        height = heights[count]
        rule_top = (settings.body_bottom - height - settings["footnote-space-after"]
                    - settings["footnote-rule-thickness"])
        page.rule("footnote", settings.body_x, rule_top,
                  settings["footnote-rule-width"], settings["footnote-rule-thickness"])
        stack_top = (rule_top + settings["footnote-rule-thickness"]
                     + settings["footnote-space-after"])
        stack = FootStack(engine)
        stack.cursor = stack_top
        face = face_name(settings["footnote-font"], False, False)
        for lines, mark in placed:
            for index, baseline in enumerate(stack.add(lines)):
                self.emit_runs(page, "footnote", lines[index], baseline)
                engine.report["lines"] += 1
                if index == 0 and mark is not None:
                    text = str(mark)
                    width = engine.face(face).text_width(text, settings["footnote-mark-size"])
                    x = (settings.body_x + settings["footnote-indent"]
                         - settings["footnote-mark-gap"] - width)
                    page.text("footnote", face, settings["footnote-mark-size"], x,
                              baseline - settings["footnote-mark-raise"], width, text)
        carried_lines = sum(len(lines) for lines, _mark in remaining)
        engine.report["footnote-split-lines"] += carried_lines
        self.carried = remaining

    def stack_heights(self, groups):
        """Cumulative stack heights after each line of the candidate list."""
        stack = FootStack(self.engine)
        heights = [0]
        for lines, _mark in groups:
            for _baseline in stack.add(lines):
                heights.append(stack.cursor)
        return heights


def build_toc(engine, entries):
    """Build the table of contents' vertical item list."""
    settings = engine.settings
    builder_root = VerticalBuilder(engine)
    title_text = engine.doc.toc_title
    if title_text is None:
        title_text = settings.text("toc-title")
    title_ctx = Context(
        family=settings["toc-title-font"], bold=settings["heading-bold"],
        italic=settings["heading-italic"], size=settings["toc-title-size"],
        leading=settings["h1-leading"], left=settings.body_x,
        measure=settings.body_width, first_indent=0,
        align=settings["heading-align"], hyphenate=settings["hyphenate"],
    )
    builder_root.leaf_space(0, settings["toc-title-space-after"])
    builder = engine.builder(title_ctx)
    hl = builder.build(builder.resolve(literal_units(title_text)))
    builder_root.emit_lines(engine.break_hlist(hl), title_ctx.leading, "other")
    face = face_name(settings["toc-font"], False, False)
    size = settings["toc-size"]
    leader = settings.text("toc-leader")
    unit = engine.face(face).text_width(leader, size)
    for entry in entries:
        builder_root.leaf_space(settings["toc-entry-space"], settings["toc-entry-space"])
        indent = (entry["level"] - 1) * settings["toc-indent"]
        ctx = Context(
            family=settings["toc-font"], bold=False, italic=False, size=size,
            leading=settings["toc-leading"], left=settings.body_x + indent,
            measure=engine.clamp(settings.body_width - indent - settings["toc-reserve"]),
            first_indent=0, align="left", hyphenate=settings["hyphenate"],
        )
        builder = engine.builder(ctx)
        resolved = []
        if entry["number"]:
            resolved.extend(builder.resolve(literal_units(entry["number"])))
            resolved.append(("rig", settings["toc-number-gap"]))
        resolved.extend(builder.resolve(literal_units(entry["plain"])))
        hl = builder.build(resolved)
        lines = engine.break_hlist(hl)
        vlines = builder_root.emit_lines(lines, ctx.leading, "other")
        label = entry["label"]
        label_width = engine.face(face).text_width(label, size)
        label_x = settings.body_x + settings.body_width - label_width
        x_from = lines[-1].end_x + settings["toc-leader-gap"]
        x_to = label_x - settings["toc-leader-gap"]
        count = max(0, fdiv(x_to - x_from, unit))
        if count > 0:
            vlines[-1].extras.append(
                (face, size, x_to - count * unit, count * unit, leader * count))
        vlines[-1].extras.append((face, size, label_x, label_width, label))
    return builder_root.items


def substitute(pieces, label, body_pages, meta, chapter, section):
    out = []
    for kind, body in pieces:
        if kind == "lit":
            out.append(body)
        elif body == "page":
            out.append(label)
        elif body == "pages":
            out.append(str(body_pages))
        elif body == "chapter":
            out.append(chapter)
        elif body == "section":
            out.append(section)
        else:
            out.append(meta.get(body, ""))
    return "".join(out)


def render_slots(engine, page, body_pages, chapter, section):
    """Place the six running header and footer slots of one page."""
    settings = engine.settings
    even = page.number % 2 == 0
    for where, baseline in (("header", settings["header-baseline"]),
                            ("footer", settings["footer-baseline"])):
        for slot in ("left", "center", "right"):
            key = "%s-%s%s" % (where, slot, "-even" if even else "")
            text = substitute(settings[key], page.label, body_pages,
                              engine.doc.meta, chapter, section)
            if not text:
                continue
            ctx = Context(
                family=settings["header-font"], bold=False, italic=False,
                size=settings["header-size"], leading=settings["leading"],
                left=settings.body_x, measure=settings.body_width,
                first_indent=0, align="left", hyphenate=False,
            )
            builder = engine.builder(ctx)
            hl = builder.build(builder.resolve(literal_units(text)))
            width = hl.natural_width()
            if slot == "left":
                x = settings.body_x
            elif slot == "center":
                x = settings.body_x + fdiv(settings.body_width - width, 2)
            else:
                x = settings.body_x + settings.body_width - width
            hl.ctx = ctx.clone(left=x)
            line = engine.set_single(hl)
            for run in line.runs:
                if not run.text:
                    continue
                page.text(where, run.face, run.size, run.x,
                          baseline - run.raise_, run.width, run.text)


def heading_title(record):
    if record["number"]:
        return record["number"] + " " + record["plain"]
    return record["plain"]


def typeset(settings, doc):
    """Lay the whole document out; returns (pages, report)."""
    engine = Engine(settings, doc)
    engine.build_footnotes()
    engine.build_figures()
    vertical = VerticalBuilder(engine)
    vertical.walk(doc.blocks, engine.root_context(), 0)
    body = Paginator(engine, vertical.items, True, True).run()
    for index, page in enumerate(body):
        page.number = settings["page-start"] + index
        page.label = str(page.number)
    front = []
    if doc.has_toc:
        entries = []
        for record in engine.headings:
            if record["starred"] or record["level"] > settings["toc-depth"]:
                continue
            index = record["page"]
            entries.append({
                "level": record["level"], "number": record["number"],
                "plain": record["plain"],
                "label": body[index].label if index is not None else "",
            })
        front = Paginator(engine, build_toc(engine, entries), False, False).run()
        for index, page in enumerate(front):
            page.number = index + 1
            page.label = roman(page.number)
    for page in front:
        render_slots(engine, page, len(body), "", "")
    chapter = ""
    section = ""
    for index, page in enumerate(body):
        for record in engine.headings:
            if record["page"] == index and record["level"] in (1, 2):
                if record["level"] == 1:
                    chapter = heading_title(record)
                else:
                    section = heading_title(record)
        render_slots(engine, page, len(body), chapter, section)
    report = dict(engine.report)
    report["pages"] = len(front) + len(body)
    report["front-pages"] = len(front)
    report["body-pages"] = len(body)
    for key, value in doc.counts.items():
        report[key] = value
    report["footnotes"] = len(doc.footnotes)
    return front + body, report
