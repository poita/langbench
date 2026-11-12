"""Recursive-descent parser: pattern text -> syntax tree (see :mod:`btregex.ast`).

Grammar::

    regex      := branch ( '|' branch )*
    branch     := piece*
    piece      := atom quantifier?
    atom       := literal | '.' | '^' | '$' | class | escape | '(' regex ')'
    quantifier := '*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}'
"""

from __future__ import annotations

from .ast import (ASCII, Alt, Any, Bol, Char, CharSet, Eol, Group, Node,
                  Repeat, Seq)
from .errors import PatternSyntaxError

_DIGITS = frozenset("0123456789")
_WORD = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
_SPACE = frozenset(" \t\n\r\f\v")

#: Set escapes (``\d`` etc.) and the character sets they denote.
SET_ESCAPES: dict[str, frozenset[str]] = {
    "d": _DIGITS,
    "D": ASCII - _DIGITS,
    "w": _WORD,
    "W": ASCII - _WORD,
    "s": _SPACE,
    "S": ASCII - _SPACE,
}

_META = frozenset("\\.[]()|*+?{}^$")
_QUANTIFIERS = frozenset("*+?{")


class Parser:
    """Parses one pattern. Use :func:`parse` for the common case."""

    def __init__(self, pattern: str) -> None:
        self.pattern = pattern
        self.pos = 0
        self.group_count = 0

    def error(self, message: str) -> PatternSyntaxError:
        return PatternSyntaxError(message, self.pattern, self.pos)

    def parse(self) -> Node:
        node = self._regex()
        if self.pos != len(self.pattern):
            raise self.error("unmatched ')'")
        return node

    def _peek(self) -> str:
        return self.pattern[self.pos] if self.pos < len(self.pattern) else ""

    def _regex(self) -> Node:
        branches = [self._branch()]
        while self._peek() == "|":
            self.pos += 1
            branches.append(self._branch())
        return branches[0] if len(branches) == 1 else Alt(branches)

    def _branch(self) -> Node:
        items: list[Node] = []
        while self.pos < len(self.pattern) and self._peek() not in "|)":
            items.append(self._piece())
        return items[0] if len(items) == 1 else Seq(items)

    def _piece(self) -> Node:
        c = self._peek()
        if c in _QUANTIFIERS:
            raise self.error("nothing to repeat")
        atom = self._atom()
        if isinstance(atom, (Bol, Eol)):
            if self._peek() in _QUANTIFIERS:
                raise self.error("anchors cannot be quantified")
            return atom
        q = self._peek()
        if q == "*":
            self.pos += 1
            atom = Repeat(atom, 0, None)
        elif q == "+":
            self.pos += 1
            atom = Repeat(atom, 1, None)
        elif q == "?":
            self.pos += 1
            atom = Repeat(atom, 0, 1)
        elif q == "{":
            atom = self._counted(atom)
        if self._peek() in _QUANTIFIERS:
            raise self.error("quantifier cannot follow a quantifier")
        return atom

    def _number(self) -> int:
        start = self.pos
        while self._peek() in _DIGITS and self._peek():
            self.pos += 1
        if start == self.pos:
            raise self.error("expected a number")
        return int(self.pattern[start:self.pos])

    def _counted(self, atom: Node) -> Node:
        self.pos += 1  # '{'
        lo = self._number()
        hi: int | None = lo
        if self._peek() == ",":
            self.pos += 1
            hi = None if self._peek() == "}" else self._number()
        if self._peek() != "}":
            raise self.error("expected '}'")
        self.pos += 1
        if hi is not None and hi < lo:
            raise self.error("min greater than max in quantifier")
        return Repeat(atom, lo, hi)

    def _atom(self) -> Node:
        c = self._peek()
        self.pos += 1
        if c == "(":
            self.group_count += 1
            index = self.group_count
            inner = self._regex()
            if self._peek() != ")":
                raise self.error("missing ')'")
            self.pos += 1
            return Group(index, inner)
        if c == ".":
            return Any()
        if c == "^":
            return Bol()
        if c == "$":
            return Eol()
        if c == "[":
            return self._class()
        if c == "\\":
            return self._escape()
        if c in _META:
            self.pos -= 1
            raise self.error(f"unexpected {c!r}")
        return Char(c)

    def _escape(self) -> Node:
        c = self._peek()
        if not c:
            raise self.error("trailing backslash")
        self.pos += 1
        if c in SET_ESCAPES:
            return CharSet(SET_ESCAPES[c])
        if c.isalnum():
            self.pos -= 1
            raise self.error(f"unsupported escape '\\{c}'")
        return Char(c)

    def _class_char(self) -> str:
        """One single character of a class (possibly backslash-escaped)."""
        c = self._peek()
        if not c:
            raise self.error("unterminated character class")
        self.pos += 1
        if c == "\\":
            c = self._peek()
            if not c or c.isalnum():
                raise self.error("bad escape in character class")
            self.pos += 1
        return c

    def _class(self) -> Node:
        negate = False
        if self._peek() == "^":
            negate = True
            self.pos += 1
        chars: set[str] = set()
        first = True
        while True:
            c = self._peek()
            if not c:
                raise self.error("unterminated character class")
            if c == "]" and not first:
                self.pos += 1
                break
            first = False
            if c == "\\" and self.pattern[self.pos + 1:self.pos + 2] in SET_ESCAPES:
                chars |= SET_ESCAPES[self.pattern[self.pos + 1]]
                self.pos += 2
                continue
            lo = self._class_char()
            if self._peek() == "-" and self.pattern[self.pos + 1:self.pos + 2] not in ("]", ""):
                self.pos += 1
                hi = self._class_char()
                if hi < lo:
                    raise self.error("bad character range")
                chars.update(map(chr, range(ord(lo), ord(hi) + 1)))
            else:
                chars.add(lo)
        result = (ASCII - chars) if negate else chars
        return CharSet(frozenset(result))


def parse(pattern: str) -> tuple[Node, int]:
    """Parse ``pattern``; return ``(tree, number_of_groups)``.

    Raises :class:`~btregex.errors.PatternSyntaxError` on invalid input.
    """
    parser = Parser(pattern)
    tree = parser.parse()
    return tree, parser.group_count
