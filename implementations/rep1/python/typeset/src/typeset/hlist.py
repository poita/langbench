"""Horizontal lists: boxes, glue and penalties built from resolved inline text."""

from __future__ import annotations

from dataclasses import dataclass

from .fonts import FontLibrary, face_name
from .inline import C, D, F, M, P, R, S
from .patterns import PatternSet
from .units import scale

BOX, GLUE, PENALTY = 0, 1, 2
INF_PENALTY = 10000


class Item:
    """One item of a horizontal list (BOX, GLUE or PENALTY).

    BOX: ``width`` and, for text boxes, ``text``/``face``/``size``/``raise_``;
    ``frag`` identifies the fragment a box came from, ``fn`` the footnote of a
    mark box.  A rigid box has ``face is None``.
    GLUE: ``width``, ``stretch``, ``shrink``, ``inf``.
    PENALTY: ``penalty``, ``flagged`` and an optional ``pre`` (a text BOX item).
    """

    __slots__ = ("kind", "width", "stretch", "shrink", "inf", "penalty", "flagged",
                 "text", "face", "size", "raise_", "frag", "fn", "pre")

    def __init__(self, kind, width=0, stretch=0, shrink=0, inf=False, penalty=0,
                 flagged=False, text=None, face=None, size=0, raise_=0, frag=-1,
                 fn=None, pre=None):
        self.kind = kind
        self.width = width
        self.stretch = stretch
        self.shrink = shrink
        self.inf = inf
        self.penalty = penalty
        self.flagged = flagged
        self.text = text
        self.face = face
        self.size = size
        self.raise_ = raise_
        self.frag = frag
        self.fn = fn
        self.pre = pre


@dataclass(frozen=True)
class BaseStyle:
    """The initial style of a horizontal list."""

    family: str
    bold: bool
    italic: bool
    size: int


@dataclass
class HyphParams:
    """Everything hyphenation needs; ``patterns`` is ``None`` when disabled."""

    patterns: PatternSet | None
    hyphen_penalty: int = 50
    ex_hyphen_penalty: int = 50


def step_size(size: int, ops: str) -> int:
    for op in ops:
        size = (size * 6) // 5 if op == "+" else (size * 5) // 6
    return size


def _is_letter(ch: str) -> bool:
    return "A" <= ch <= "Z" or "a" <= ch <= "z"


_CLOSERS = frozenset(")]}'\"’”")


def sentence_end(units: list, idx: int) -> bool:
    """Does the space at ``units[idx]`` follow a sentence end?"""
    j = idx - 1
    found = False
    while j >= 0:
        u = units[j]
        kind = u[0]
        if kind == D:
            j -= 1
            continue
        if kind != C:
            return False
        ch = u[1]
        if ch in _CLOSERS:
            j -= 1
            continue
        if ch in ".!?":
            found = True
            j -= 1
            break
        return False
    if not found:
        return False
    while j >= 0 and units[j][0] == D:
        j -= 1
    if j < 0 or units[j][0] != C:
        return True
    return not ("A" <= units[j][1] <= "Z")


class HList:
    """A built horizontal list."""

    __slots__ = ("items", "footnotes")

    def __init__(self, items: list[Item], footnotes: list) -> None:
        self.items = items
        self.footnotes = footnotes


class HListBuilder:
    """Builds horizontal lists from resolved units (see :mod:`typeset.inline`)."""

    def __init__(self, fonts: FontLibrary, mark_size: int, mark_raise: int,
                 hyph: HyphParams, ragged_stretch: int) -> None:
        self.fonts = fonts
        self.mark_size = mark_size
        self.mark_raise = mark_raise
        self.hyph = hyph
        self.ragged = ragged_stretch
        self._frag = 0

    def build(self, units: list, base: BaseStyle, align: str, hyphenate: bool) -> HList:
        fonts = self.fonts
        resolved: dict = {}

        def resolve(style):
            r = resolved.get(style)
            if r is None:
                bold, italic, mono, ops = style
                family = "mono" if mono else base.family
                face = fonts.get(face_name(family, base.bold or bold, base.italic or italic))
                r = (face, step_size(base.size, ops))
                resolved[style] = r
            return r

        justify = align == "justify"
        ragged = self.ragged
        items: list[Item] = []
        footnotes: list = []
        hyph_on = hyphenate and self.hyph.patterns is not None

        chars: list[str] = []
        points: list[int] = []
        cur_face = None
        cur_size = 0

        def flush():
            nonlocal chars, points
            if not chars:
                return
            text = "".join(chars)
            self._emit_fragment(items, text, points, cur_face, cur_size, hyph_on)
            chars = []
            points = []

        def glue(face, size, extra):
            sp = face.space
            st = face.stretch
            if extra:
                w = scale(sp + face.extra, size)
                y = scale(st + st // 2, size)
            else:
                w = scale(sp, size)
                y = scale(st, size)
            z = scale(face.shrink, size)
            if not justify:
                y = ragged * w
                z = 0
            items.append(Item(GLUE, width=w, stretch=y, shrink=z))

        for idx, u in enumerate(units):
            kind = u[0]
            if kind == C:
                face, size = resolve(u[2])
                if chars and (face is not cur_face or size != cur_size):
                    flush()
                cur_face, cur_size = face, size
                chars.append(u[1])
            elif kind == D:
                if chars:
                    points.append(len(chars))
            elif kind == S:
                flush()
                face, size = resolve(u[1])
                glue(face, size, sentence_end(units, idx))
            elif kind == P:
                flush()
                face, size = resolve(u[1])
                glue(face, size, False)
            elif kind == R:
                flush()
                face, size = resolve(u[1])
                items.append(Item(BOX, width=scale(face.space, size)))
            elif kind == F:
                flush()
                items.append(Item(BOX, width=u[1]))
            elif kind == M:
                flush()
                fn = u[1]
                face, _ = resolve(u[2])
                text = str(fn.number)
                self._frag += 1
                items.append(Item(BOX, width=face.width(text, self.mark_size), text=text,
                                  face=face, size=self.mark_size, raise_=self.mark_raise,
                                  frag=self._frag, fn=fn))
                footnotes.append(fn)
        flush()
        items.append(Item(PENALTY, penalty=INF_PENALTY))
        items.append(Item(GLUE, inf=True))
        items.append(Item(PENALTY, penalty=-INF_PENALTY))
        return HList(items, footnotes)

    # -- fragments ---------------------------------------------------------

    def _emit_fragment(self, items, text, points, face, size, hyph_on) -> None:
        self._frag += 1
        frag = self._frag
        n = len(text)
        breaks = self._hyphenation_points(text, points, face, hyph_on) if hyph_on else None
        if not breaks:
            items.append(Item(BOX, width=face.width(text, size), text=text, face=face,
                              size=size, frag=frag))
            return
        hp = self.hyph
        hyphen_w = face.width("-", size)
        prev = 0
        for pos in sorted(breaks):
            kind = breaks[pos]
            piece = text[prev:pos]
            items.append(Item(BOX, width=face.width(piece, size), text=piece, face=face,
                              size=size, frag=frag))
            if kind == "core":
                items.append(Item(PENALTY, penalty=hp.ex_hyphen_penalty, flagged=True))
            else:
                pre = Item(BOX, width=hyphen_w, text="-", face=face, size=size, frag=frag)
                items.append(Item(PENALTY, penalty=hp.hyphen_penalty, flagged=True, pre=pre))
            prev = pos
        piece = text[prev:n]
        items.append(Item(BOX, width=face.width(piece, size), text=piece, face=face,
                          size=size, frag=frag))

    def _hyphenation_points(self, text, points, face, hyph_on):
        """Map position -> "core" | "hyphen" for the fragment, or ``None``."""
        if face.is_mono:
            return None
        n = len(text)
        lo = next((i for i in range(n) if _is_letter(text[i])), -1)
        if lo < 0:
            return None
        hi = max(i for i in range(n) if _is_letter(text[i])) + 1
        result: dict[int, str] = {}
        explicit = sorted({p for p in points if 0 < p < n})
        # core hyphens
        for i in range(lo, hi):
            if text[i] == "-":
                result[i + 1] = "core"
        if explicit:
            for p in explicit:
                result.setdefault(p, "hyphen")
            return result
        patterns = self.hyph.patterns
        start = lo
        for seg_end in [i for i in range(lo, hi) if text[i] == "-"] + [hi]:
            seg = text[start:seg_end]
            if seg and all(_is_letter(ch) for ch in seg):
                for q in patterns.breaks(seg.lower()):
                    result.setdefault(start + q, "hyphen")
            start = seg_end + 1
        return result
