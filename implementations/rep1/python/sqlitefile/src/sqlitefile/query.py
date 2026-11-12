"""Parsing of the five-command query language (spec Part 4)."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .errors import QueryError
from .record import Value

_WORD = re.compile(r"[A-Za-z0-9_]+")
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUMERAL = re.compile(r"[+-]?[0-9]+(\.[0-9]*)?([eE][+-]?[0-9]+)?")
_HEX = re.compile(r"[0-9A-Fa-f]*")
_BLANKS = " \t"

#: The eight comparison operators, as written in the canonical (upper-case) form.
OPERATORS = ("=", "!=", "<", "<=", ">", ">=", "IS", "IS NOT")


@dataclass(frozen=True, slots=True)
class Condition:
    column: str
    op: str  #: one of :data:`OPERATORS`
    literal: Value


@dataclass(frozen=True, slots=True)
class OrderBy:
    column: str
    descending: bool = False


@dataclass(frozen=True, slots=True)
class TablesQuery:
    """``.tables``"""


@dataclass(frozen=True, slots=True)
class SchemaQuery:
    """``.schema <table>``"""

    table: str


@dataclass(frozen=True, slots=True)
class CountQuery:
    """``COUNT <table>``"""

    table: str


@dataclass(frozen=True, slots=True)
class SelectQuery:
    """``SELECT`` with optional ``WHERE``, ``ORDER BY`` and ``LIMIT``."""

    table: str
    columns: tuple[str, ...] | None  #: ``None`` means ``*``
    where: tuple[Condition, ...] = ()
    order_by: OrderBy | None = None
    limit: int | None = None


@dataclass(frozen=True, slots=True)
class IndexQuery:
    """``INDEX <index-name> <literal>``"""

    index: str
    literal: Value


Query = TablesQuery | SchemaQuery | CountQuery | SelectQuery | IndexQuery


def parse_query(line: str) -> Query:
    """Parse one query line, raising :class:`QueryError` if it is malformed."""
    if line.startswith("."):
        return _parse_dot_command(line)
    return _Parser(line).parse()


def _parse_dot_command(line: str) -> Query:
    if line == ".tables":
        return TablesQuery()
    if line.startswith(".schema "):
        arg = line[len(".schema ") :]
        if _IDENT.fullmatch(arg):
            return SchemaQuery(arg)
    raise QueryError(f"bad command: {line!r}")


class _Parser:
    """A single-pass scanner over one query line.

    Words are maximal runs of ``[A-Za-z0-9_]``, so two adjacent words can never
    be mistaken for one another; everything else is optionally space-separated.
    """

    def __init__(self, text: str) -> None:
        self.text = text
        self.pos = 0

    # -- scanning helpers -------------------------------------------------

    def fail(self, why: str) -> QueryError:
        return QueryError(f"{why} at offset {self.pos} in {self.text!r}")

    def skip_blanks(self) -> None:
        t, p = self.text, self.pos
        while p < len(t) and t[p] in _BLANKS:
            p += 1
        self.pos = p

    def at_end(self) -> bool:
        self.skip_blanks()
        return self.pos >= len(self.text)

    def peek_word(self) -> str | None:
        self.skip_blanks()
        m = _WORD.match(self.text, self.pos)
        return m.group() if m else None

    def word(self) -> str:
        w = self.peek_word()
        if w is None:
            raise self.fail("expected a word")
        self.pos += len(w)
        return w

    def keyword(self, kw: str) -> None:
        if self.word().upper() != kw:
            raise self.fail(f"expected {kw}")

    def accept_keyword(self, kw: str) -> bool:
        w = self.peek_word()
        if w is not None and w.upper() == kw:
            self.pos += len(w)
            return True
        return False

    def ident(self) -> str:
        w = self.word()
        if not _IDENT.fullmatch(w):
            raise self.fail("expected an identifier")
        return w

    def accept(self, s: str) -> bool:
        self.skip_blanks()
        if self.text.startswith(s, self.pos):
            self.pos += len(s)
            return True
        return False

    def finish(self) -> None:
        if not self.at_end():
            raise self.fail("unexpected trailing text")

    # -- grammar ----------------------------------------------------------

    def parse(self) -> Query:
        cmd = self.word().upper()
        if cmd == "SELECT":
            return self.select()
        if cmd == "COUNT":
            q = CountQuery(self.ident())
        elif cmd == "INDEX":
            name = self.ident()
            q = IndexQuery(name, self.literal())
        else:
            raise self.fail("unknown command")
        self.finish()
        return q

    def select(self) -> SelectQuery:
        columns: tuple[str, ...] | None
        if self.accept("*"):
            columns = None
        else:
            names = [self.ident()]
            while self.accept(","):
                names.append(self.ident())
            columns = tuple(names)
        self.keyword("FROM")
        table = self.ident()
        where: list[Condition] = []
        if self.accept_keyword("WHERE"):
            where.append(self.condition())
            while self.accept_keyword("AND"):
                where.append(self.condition())
        order_by = None
        if self.accept_keyword("ORDER"):
            self.keyword("BY")
            column = self.ident()
            descending = False
            if self.accept_keyword("DESC"):
                descending = True
            else:
                self.accept_keyword("ASC")
            order_by = OrderBy(column, descending)
        limit = None
        if self.accept_keyword("LIMIT"):
            digits = self.word()
            if not (digits.isascii() and digits.isdigit()):
                raise self.fail("LIMIT needs an unsigned integer")
            limit = int(digits)
        self.finish()
        return SelectQuery(table, columns, tuple(where), order_by, limit)

    def condition(self) -> Condition:
        column = self.ident()
        self.skip_blanks()
        t, p = self.text, self.pos
        if t.startswith("!=", p):
            op = "!="
        elif t.startswith("<=", p):
            op = "<="
        elif t.startswith(">=", p):
            op = ">="
        elif p < len(t) and t[p] in "=<>":
            op = t[p]
        else:
            if not self.accept_keyword("IS"):
                raise self.fail("expected a comparison operator")
            op = "IS NOT" if self.accept_keyword("NOT") else "IS"
            return Condition(column, op, self.literal())
        self.pos += len(op)
        return Condition(column, op, self.literal())

    def literal(self) -> Value:
        self.skip_blanks()
        t, p = self.text, self.pos
        if p >= len(t):
            raise self.fail("expected a literal")
        c = t[p]
        if c == "'":
            return self.string(p + 1)
        if c in "xX" and t.startswith("'", p + 1):
            end = t.find("'", p + 2)
            digits = t[p + 2 : end] if end >= 0 else ""
            if end < 0 or len(digits) % 2 or not _HEX.fullmatch(digits):
                raise self.fail("malformed blob literal")
            self.pos = end + 1
            return bytes.fromhex(digits)
        m = _NUMERAL.match(t, p)
        if m:
            end = m.end()
            if end < len(t) and (t[end] in "_." or _WORD.match(t, end)):
                raise self.fail("malformed numeral")
            self.pos = end
            if m.group(1) is None and m.group(2) is None:
                return int(m.group())
            return float(m.group())
        w = _WORD.match(t, p)
        if w and w.group().upper() == "NULL":
            self.pos = w.end()
            return None
        raise self.fail("malformed literal")

    def string(self, start: int) -> str:
        t = self.text
        parts: list[str] = []
        p = start
        while True:
            q = t.find("'", p)
            if q < 0:
                raise self.fail("unterminated string")
            parts.append(t[p:q])
            if t.startswith("'", q + 1):
                parts.append("'")
                p = q + 2
            else:
                self.pos = q + 1
                return "".join(parts)
