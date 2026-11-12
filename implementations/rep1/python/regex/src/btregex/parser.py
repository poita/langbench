"""Recursive-descent parser: pattern text -> syntax tree.

Grammar (see the project README for the full syntax)::

    regex      := branch ( '|' branch )*
    branch     := piece*
    piece      := atom quantifier?
    atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
    quantifier := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}'
"""

from __future__ import annotations

from .errors import PatternSyntaxError
from .nodes import (
    AnyChar,
    Alternation,
    CharClass,
    EndAnchor,
    Group,
    Literal,
    Node,
    Repeat,
    Sequence,
    StartAnchor,
)

_ASCII = frozenset(map(chr, range(128)))
_DIGITS = frozenset("0123456789")
_WORD = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
_SPACE = frozenset(" \t\n\r\f\v")

#: Escapes that denote a set of characters (valid inside and outside classes).
SET_ESCAPES: dict[str, frozenset[str]] = {
    "d": _DIGITS,
    "D": _ASCII - _DIGITS,
    "w": _WORD,
    "W": _ASCII - _WORD,
    "s": _SPACE,
    "S": _ASCII - _SPACE,
}

_METACHARACTERS = frozenset("\\.[]()|*+?{}^$")
_QUANTIFIER_STARTS = frozenset("*+?{")


class _Parser:
    def __init__(self, pattern: str) -> None:
        self.p = pattern
        self.pos = 0
        self.groups = 0

    def error(self, message: str) -> PatternSyntaxError:
        return PatternSyntaxError(message, self.p, self.pos)

    # -- structure -------------------------------------------------------

    def parse(self) -> Node:
        node = self.regex()
        if self.pos != len(self.p):
            raise self.error("unbalanced ')'")
        return node

    def regex(self) -> Node:
        branches = [self.branch()]
        while self.pos < len(self.p) and self.p[self.pos] == "|":
            self.pos += 1
            branches.append(self.branch())
        if len(branches) == 1:
            return branches[0]
        return Alternation(tuple(branches))

    def branch(self) -> Node:
        items: list[Node] = []
        p = self.p
        while self.pos < len(p) and p[self.pos] not in "|)":
            items.append(self.piece())
        if len(items) == 1:
            return items[0]
        return Sequence(tuple(items))

    def piece(self) -> Node:
        atom = self.atom()
        p = self.p
        if self.pos < len(p) and p[self.pos] in _QUANTIFIER_STARTS:
            if isinstance(atom, (StartAnchor, EndAnchor)):
                raise self.error("anchors cannot be quantified")
            lo, hi = self.quantifier()
            return Repeat(atom, lo, hi)
        return atom

    def quantifier(self) -> tuple[int, int | None]:
        p = self.p
        c = p[self.pos]
        self.pos += 1
        if c == "*":
            return 0, None
        if c == "+":
            return 1, None
        if c == "?":
            return 0, 1
        lo = self.number()
        hi: int | None = lo
        if self.pos < len(p) and p[self.pos] == ",":
            self.pos += 1
            hi = None if p[self.pos : self.pos + 1] == "}" else self.number()
        if p[self.pos : self.pos + 1] != "}":
            raise self.error("expected '}'")
        self.pos += 1
        if hi is not None and hi < lo:
            raise self.error("quantifier maximum is below its minimum")
        return lo, hi

    def number(self) -> int:
        p = self.p
        start = self.pos
        while self.pos < len(p) and p[self.pos].isdigit():
            self.pos += 1
        if start == self.pos:
            raise self.error("expected a number")
        return int(p[start : self.pos])

    # -- atoms -----------------------------------------------------------

    def atom(self) -> Node:
        p = self.p
        c = p[self.pos]
        self.pos += 1
        if c == "(":
            self.groups += 1
            index = self.groups
            body = self.regex()
            if p[self.pos : self.pos + 1] != ")":
                raise self.error("missing ')'")
            self.pos += 1
            return Group(index, body)
        if c == ".":
            return AnyChar()
        if c == "^":
            return StartAnchor()
        if c == "$":
            return EndAnchor()
        if c == "[":
            return self.char_class()
        if c == "\\":
            return self.escape()
        if c in _METACHARACTERS:
            self.pos -= 1
            raise self.error(f"unexpected {c!r}")
        return Literal(c)

    def escape(self) -> Node:
        p = self.p
        if self.pos >= len(p):
            raise self.error("trailing backslash")
        c = p[self.pos]
        self.pos += 1
        if c in SET_ESCAPES:
            return CharClass(SET_ESCAPES[c])
        if c.isalnum():
            self.pos -= 1
            raise self.error(f"unsupported escape '\\{c}'")
        return Literal(c)

    # -- character classes ----------------------------------------------

    def class_char(self) -> str:
        """Parse one single-character class member (possibly escaped)."""
        p = self.p
        c = p[self.pos]
        self.pos += 1
        if c == "\\":
            if self.pos >= len(p):
                raise self.error("trailing backslash")
            c = p[self.pos]
            self.pos += 1
            if c.isalnum():
                self.pos -= 1
                raise self.error(f"unsupported escape '\\{c}' in class")
        return c

    def char_class(self) -> Node:
        p = self.p
        negate = False
        if p[self.pos : self.pos + 1] == "^":
            negate = True
            self.pos += 1
        members: set[str] = set()
        first = True
        while True:
            if self.pos >= len(p):
                raise self.error("unterminated character class")
            c = p[self.pos]
            if c == "]" and not first:
                self.pos += 1
                break
            first = False
            if c == "\\" and p[self.pos + 1 : self.pos + 2] in SET_ESCAPES:
                members |= SET_ESCAPES[p[self.pos + 1]]
                self.pos += 2
                continue
            lo = self.class_char()
            if p[self.pos : self.pos + 1] == "-" and p[self.pos + 1 : self.pos + 2] not in ("]", ""):
                self.pos += 1
                hi = self.class_char()
                if hi < lo:
                    raise self.error("reversed range in character class")
                members.update(map(chr, range(ord(lo), ord(hi) + 1)))
            else:
                members.add(lo)
        chars = frozenset(members)
        if negate:
            chars = _ASCII - chars
        return CharClass(chars)


def parse(pattern: str) -> tuple[Node, int]:
    """Parse ``pattern`` and return ``(tree, number_of_groups)``.

    Raises :class:`~btregex.errors.PatternSyntaxError` for invalid patterns.
    """
    parser = _Parser(pattern)
    tree = parser.parse()
    return tree, parser.groups
