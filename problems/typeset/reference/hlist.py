"""Horizontal lists: fragments, boxes, glue, marks and hyphenation."""

from metrics import scale, face_name

SKIPPABLE = set(") ] } ' \" ’ ”".split(" "))
SKIPPABLE = {")", "]", "}", "'", '"', "’", "”"}
SENTENCE_ENDERS = {".", "!", "?"}


def step_up(size):
    return (size * 6) // 5


def step_down(size):
    return (size * 5) // 6


class Context:
    """Everything a horizontal list needs besides its inline text."""

    def __init__(self, family, bold, italic, size, leading, left, measure,
                 first_indent, align, hyphenate):
        self.family = family
        self.bold = bold
        self.italic = italic
        self.size = size
        self.leading = leading
        self.left = left
        self.measure = measure
        self.first_indent = first_indent
        self.align = align
        self.hyphenate = hyphenate

    def clone(self, **changes):
        ctx = Context(self.family, self.bold, self.italic, self.size,
                      self.leading, self.left, self.measure,
                      self.first_indent, self.align, self.hyphenate)
        for key, value in changes.items():
            setattr(ctx, key, value)
        return ctx

    def resolve(self, style):
        """Resolve an inline style against this context into (face, size)."""
        mono, bold, italic, ops = style
        family = "mono" if mono else self.family
        size = self.size
        for op in ops:
            size = step_up(size) if op > 0 else step_down(size)
        return face_name(family, self.bold or bold, self.italic or italic), size

    def base_face(self):
        return face_name(self.family, self.bold, self.italic)


class Box:
    """A run of glyphs, or a rigid box (face None, no text, fixed width)."""

    __slots__ = ("face", "size", "raise_", "text", "width", "frag", "mark")

    def __init__(self, face, size, raise_, text, width, frag, mark=None):
        self.face = face
        self.size = size
        self.raise_ = raise_
        self.text = text
        self.width = width
        self.frag = frag
        self.mark = mark


class Glue:
    __slots__ = ("w", "y", "z", "infinite")

    def __init__(self, w, y, z, infinite=False):
        self.w = w
        self.y = y
        self.z = z
        self.infinite = infinite


class Penalty:
    __slots__ = ("p", "flagged", "pre")

    def __init__(self, p, flagged, pre=None):
        self.p = p
        self.flagged = flagged
        self.pre = pre


class HList:
    """A finished horizontal list plus the prefix sums line breaking needs."""

    def __init__(self, items, ctx):
        self.items = items
        self.ctx = ctx
        self.prepare()

    def prepare(self):
        items = self.items
        n = len(items)
        self.cum_w = [0] * (n + 1)
        self.cum_y = [0] * (n + 1)
        self.cum_z = [0] * (n + 1)
        self.cum_inf = [0] * (n + 1)
        for i, item in enumerate(items):
            w = y = z = 0
            inf = 0
            if isinstance(item, Box):
                w = item.width
            elif isinstance(item, Glue):
                w, y, z = item.w, item.y, item.z
                inf = 1 if item.infinite else 0
            self.cum_w[i + 1] = self.cum_w[i] + w
            self.cum_y[i + 1] = self.cum_y[i] + y
            self.cum_z[i + 1] = self.cum_z[i] + z
            self.cum_inf[i + 1] = self.cum_inf[i] + inf
        # First index at or after i that is not a GLUE, for leading-glue removal.
        self.next_box = [n] * (n + 1)
        nxt = n
        for i in range(n - 1, -1, -1):
            if not isinstance(items[i], Glue):
                nxt = i
            self.next_box[i] = nxt
        self.next_box[n] = n
        self.breaks = [0]
        for i, item in enumerate(items):
            if isinstance(item, Glue):
                if i > 0 and isinstance(items[i - 1], Box):
                    self.breaks.append(i)
            elif isinstance(item, Penalty) and item.p < 10000:
                self.breaks.append(i)

    def break_penalty(self, b):
        if b == 0:
            return 0
        item = self.items[b]
        return item.p if isinstance(item, Penalty) else 0

    def break_flagged(self, b):
        if b == 0:
            return False
        item = self.items[b]
        return bool(isinstance(item, Penalty) and item.flagged)

    def line_start(self, a):
        """The index of the first item of a line that starts at breakpoint a."""
        return self.next_box[0 if a == 0 else a + 1]

    def line_metrics(self, a, b):
        """(W, Y, Z, infinite) of the line between breakpoints a and b."""
        start = self.line_start(a)
        if start > b:
            start = b
        w = self.cum_w[b] - self.cum_w[start]
        y = self.cum_y[b] - self.cum_y[start]
        z = self.cum_z[b] - self.cum_z[start]
        inf = self.cum_inf[b] - self.cum_inf[start]
        item = self.items[b] if b < len(self.items) else None
        if isinstance(item, Penalty) and item.pre is not None:
            w += item.pre.width
        return w, y, z, inf > 0

    def natural_width(self):
        """Natural width of the whole list, excluding the final infinite glue."""
        total = 0
        for item in self.items:
            if isinstance(item, Box):
                total += item.width
            elif isinstance(item, Glue) and not item.infinite:
                total += item.w
        return total

    def min_width(self):
        """The widest line the list could produce between adjacent breakpoints."""
        widest = 0
        for index in range(1, len(self.breaks)):
            a = self.breaks[index - 1]
            b = self.breaks[index]
            w, _y, _z, _inf = self.line_metrics(a, b)
            if w > widest:
                widest = w
        return widest


class Builder:
    """Turns unit streams into horizontal lists using one context."""

    def __init__(self, engine, ctx):
        self.engine = engine
        self.ctx = ctx
        self.frag_counter = 0

    def face(self, name):
        return self.engine.metrics.face(name)

    # -- resolving a unit stream -----------------------------------------

    def resolve(self, units):
        """Resolve units into (kind, ...) tuples with glue runs collapsed."""
        ctx = self.ctx
        settings = self.engine.settings
        out = []
        i = 0
        n = len(units)
        while i < n:
            unit = units[i]
            kind = unit[0]
            if kind == "sp":
                face, size = ctx.resolve(unit[1])
                run_end = i
                while run_end < n and units[run_end][0] == "sp":
                    run_end += 1
                out.append(self.make_glue(face, size, out))
                i = run_end
                continue
            if kind == "ch":
                face, size = ctx.resolve(unit[2])
                out.append(("ch", unit[1], face, size, 0))
            elif kind == "rig":
                face, size = ctx.resolve(unit[1])
                out.append(("rig", scale(self.face(face).space, size)))
            elif kind == "disc":
                out.append(("disc",))
            elif kind == "mark":
                face, size = ctx.resolve(unit[2])
                out.append((
                    "mark", unit[1], face, settings["mark-size"],
                    settings["mark-raise"],
                ))
            i += 1
        while out and out[0][0] == "glue":
            out.pop(0)
        while out and out[-1][0] == "glue":
            out.pop()
        return out

    def make_glue(self, face_id, size, prefix):
        face = self.face(face_id)
        if self.sentence_end(prefix):
            w = scale(face.space + face.extra, size)
            y = scale(face.stretch + (face.stretch // 2), size)
            z = scale(face.shrink, size)
        else:
            w = scale(face.space, size)
            y = scale(face.stretch, size)
            z = scale(face.shrink, size)
        return ("glue", w, y, z)

    @staticmethod
    def sentence_end(prefix):
        """Whether the characters before a space run end a sentence."""
        j = len(prefix) - 1
        while j >= 0:
            unit = prefix[j]
            if unit[0] == "disc":
                j -= 1
                continue
            if unit[0] == "ch" and unit[1] in SKIPPABLE:
                j -= 1
                continue
            break
        if j < 0:
            return False
        unit = prefix[j]
        if unit[0] != "ch" or unit[1] not in SENTENCE_ENDERS:
            return False
        k = j - 1
        while k >= 0 and prefix[k][0] == "disc":
            k -= 1
        if k >= 0:
            before = prefix[k]
            if before[0] == "ch" and "A" <= before[1] <= "Z":
                return False
        return True

    # -- items -----------------------------------------------------------

    def new_frag(self):
        self.frag_counter += 1
        return self.frag_counter

    def text_box(self, face_id, size, raise_, text, frag, mark=None):
        width = self.face(face_id).text_width(text, size)
        return Box(face_id, size, raise_, text, width, frag, mark)

    def build(self, resolved, prepend=None):
        """Assemble resolved units (optionally after `prepend`) into an HList."""
        items = list(prepend) if prepend else []
        pending = []
        pending_key = None
        pending_discs = []

        def flush():
            if pending:
                items.extend(self.make_fragment(pending_key, pending, pending_discs))
            del pending[:]
            del pending_discs[:]

        for unit in resolved:
            kind = unit[0]
            if kind == "ch":
                key = (unit[2], unit[3], unit[4])
                if pending and key != pending_key:
                    flush()
                    pending_key = key
                elif not pending:
                    pending_key = key
                pending.append(unit[1])
            elif kind == "disc":
                if pending:
                    pending_discs.append(len(pending))
                continue
            else:
                flush()
                if kind == "glue":
                    items.append(Glue(unit[1], unit[2], unit[3]))
                elif kind == "rig":
                    items.append(Box(None, 0, 0, "", unit[1], self.new_frag()))
                elif kind == "mark":
                    items.append(self.text_box(unit[2], unit[3], unit[4],
                                               str(unit[1]), self.new_frag(),
                                               mark=unit[1]))
        flush()
        self.apply_ragged(items)
        items.append(Penalty(10000, False))
        items.append(Glue(0, 0, 0, True))
        items.append(Penalty(-10000, False))
        return HList(items, self.ctx)

    def apply_ragged(self, items):
        if self.ctx.align == "justify":
            return
        stretch = self.engine.settings["ragged-stretch"]
        for item in items:
            if isinstance(item, Glue) and not item.infinite:
                item.y = stretch * item.w
                item.z = 0

    # -- fragments and hyphenation ---------------------------------------

    def make_fragment(self, key, chars, discs):
        face_id, size, raise_ = key
        text = "".join(chars)
        frag = self.new_frag()
        points = self.hyphenation_points(text, discs, face_id, size)
        if not points:
            return [self.text_box(face_id, size, raise_, text, frag)]
        out = []
        prev = 0
        for pos, penalty, flagged, pre_text in points:
            out.append(self.text_box(face_id, size, raise_, text[prev:pos], frag))
            pre = None
            if pre_text:
                pre = self.text_box(face_id, size, raise_, pre_text, frag)
            out.append(Penalty(penalty, flagged, pre))
            prev = pos
        out.append(self.text_box(face_id, size, raise_, text[prev:], frag))
        return out

    def hyphenation_points(self, text, discs, face_id, size):
        """The sorted hyphenation points of one fragment."""
        engine = self.engine
        settings = engine.settings
        if not (self.ctx.hyphenate and settings["hyphenate"]):
            return []
        if face_id == "mono":
            return []
        if not any(is_letter(ch) for ch in text):
            return []
        n = len(text)
        lo = 0
        while lo < n and not is_letter(text[lo]):
            lo += 1
        hi = n
        while hi > lo and not is_letter(text[hi - 1]):
            hi -= 1
        if lo >= hi:
            return []
        table = {}
        explicit = [p for p in discs if 0 < p < n]
        if explicit:
            for pos in explicit:
                table[pos] = (settings["hyphen-penalty"], True, "-")
        else:
            pset = engine.patterns()
            start = lo
            for cut in range(lo, hi + 1):
                if cut == hi or text[cut] == "-":
                    segment = text[start:cut]
                    if segment and all(is_letter(ch) for ch in segment):
                        for q in liang(segment.lower(), pset):
                            table[start + q] = (settings["hyphen-penalty"], True, "-")
                    start = cut + 1
        for pos in range(lo, hi):
            if text[pos] == "-":
                table[pos + 1] = (settings["ex-hyphen-penalty"], True, "")
        return [(pos,) + table[pos] for pos in sorted(table)]


def is_letter(ch):
    return ("a" <= ch <= "z") or ("A" <= ch <= "Z")


def liang(segment, pset):
    """Liang's algorithm: the permitted break positions of one lowercase word."""
    breaks = pset.exceptions.get(segment)
    n = len(segment)
    if breaks is None:
        t = "." + segment + "."
        total = len(t)
        values = [0] * (total + 1)
        limit = pset.max_key
        patterns = pset.patterns
        for i in range(total):
            top = min(total, i + limit)
            for j in range(i + 1, top + 1):
                found = patterns.get(t[i:j])
                if found is not None:
                    for k, value in enumerate(found):
                        if value > values[i + k]:
                            values[i + k] = value
        breaks = [q for q in range(1, n) if values[1 + q] % 2 == 1]
    return [q for q in breaks if pset.left <= q <= n - pset.right]
