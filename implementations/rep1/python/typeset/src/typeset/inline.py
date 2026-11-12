"""The inline markup scanner.

Turns a block's inline text into a *resolved stream* of units.  A unit is a
tuple whose first element is one of the kind constants below:

``(C, char, style)``      an ordinary character
``(S, style)``            inter-word space (runs of spaces already collapsed)
``(R, style)``            a rigid space (``~`` or ``\\ ``)
``(D,)``                  a discretionary hyphenation point (``\\-``)
``(M, footnote, style)``  a footnote reference mark
``(P, style)``            a space that never takes the sentence-end extra space
``(F, width)``            a rigid box of fixed width

A *style* is ``(bold, italic, mono, size_ops)`` where ``size_ops`` is a string
of ``+``/``-`` steps applied in order to the context size.
"""

from __future__ import annotations

from collections.abc import Callable

from .errors import CodexaError

C, S, R, D, M, P, F = range(7)

ROOT_STYLE = (False, False, False, "")

_TAGS = "bimn+-"
_ESCAPES = "{}|\\@~"


class Footnote:
    """A ``{n|...}`` footnote: its number, its resolved units and, once laid
    out, its lines."""

    __slots__ = ("number", "units", "lines")

    def __init__(self, number: int) -> None:
        self.number = number
        self.units: list = []
        self.lines: list = []


def finalize(units: list) -> list:
    """Remove a glue at the very start and the very end (whitespace rule 2)."""
    start, end = 0, len(units)
    if end and units[0][0] == S:
        start = 1
    if end > start and units[end - 1][0] == S:
        end -= 1
    return units[start:end] if (start or end != len(units)) else units


class FootnoteCounter:
    """Hands out footnote numbers in source order."""

    def __init__(self) -> None:
        self.count = 0

    def next(self) -> Footnote:
        self.count += 1
        return Footnote(self.count)


def scan_inline(
    text: str,
    where: Callable[[int], tuple[int, int]],
    file: str,
    counter: FootnoteCounter,
    allow_footnote: bool = True,
) -> list:
    """Scan *text*; ``where(i)`` maps a character index to ``(line, col)``.

    Raises :class:`CodexaError` for the first inline error.
    """

    def fail(code: str, i: int):
        line, col = where(i)
        raise CodexaError(file, line, col, code)

    out: list = []
    style = ROOT_STYLE
    # Each frame: (tag, open index, saved style, saved out, footnote or None)
    stack: list = []
    in_footnote = False
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == " ":
            if not out or out[-1][0] != S:
                out.append((S, style))
            i += 1
        elif c == "{":
            tag = text[i + 1] if i + 1 < n else ""
            if tag == "" or tag not in _TAGS or i + 2 >= n or text[i + 2] != "|":
                fail("unknown-inline", i)
            if tag == "n":
                if not allow_footnote:
                    fail("footnote-not-allowed", i)
                if in_footnote:
                    fail("nested-footnote", i)
                fn = counter.next()
                stack.append((tag, i, style, out, fn))
                out = []
                style = ROOT_STYLE
                in_footnote = True
            else:
                stack.append((tag, i, style, out, None))
                bold, italic, mono, ops = style
                if tag == "b":
                    bold = True
                elif tag == "i":
                    italic = True
                elif tag == "m":
                    mono = True
                else:
                    ops += tag
                style = (bold, italic, mono, ops)
            i += 3
        elif c == "}":
            if not stack:
                fail("stray-brace", i)
            tag, _pos, saved_style, saved_out, fn = stack.pop()
            if fn is not None:
                fn.units = finalize(out)
                out = saved_out
                in_footnote = False
                out.append((M, fn, saved_style))
            style = saved_style
            i += 1
        elif c == "\\":
            nxt = text[i + 1] if i + 1 < n else ""
            if nxt and nxt in _ESCAPES:
                out.append((C, nxt, style))
            elif nxt == " ":
                out.append((R, style))
            elif nxt == "-":
                out.append((D,))
            else:
                fail("bad-escape", i)
            i += 2
        elif c == "~":
            out.append((R, style))
            i += 1
        else:
            out.append((C, c, style))
            i += 1
    if stack:
        fail("unclosed-inline", stack[-1][1])
    return finalize(out)
