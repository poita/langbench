"""Parsing of ``CREATE TABLE`` and ``CREATE INDEX`` statements (spec Part 2).

Only the pieces a reader needs are extracted: column names and declared types,
the rowid alias, and an index's table and column list.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import NamedTuple

from .errors import FormatError
from .values import affinity_of, ascii_upper


class Token(NamedTuple):
    kind: str  #: ``word``, ``quoted``, ``string`` or ``punct``
    text: str  #: unquoted text for ``quoted``; raw text otherwise

    def is_kw(self, *names: str) -> bool:
        """True for an unquoted word equal (ASCII case-insensitively) to a keyword."""
        return self.kind == "word" and ascii_upper(self.text) in names


_WORD_CHARS = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$")
_CLOSERS = {'"': '"', "`": "`", "[": "]"}


def tokenize(sql: str) -> list[Token]:
    """Split SQL text into tokens, dropping whitespace and comments."""
    tokens: list[Token] = []
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        if c.isspace():
            i += 1
        elif c == "-" and sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j + 1
        elif c == "/" and sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c in _WORD_CHARS:
            j = i + 1
            while j < n and sql[j] in _WORD_CHARS:
                j += 1
            tokens.append(Token("word", sql[i:j]))
            i = j
        elif c in _CLOSERS or c == "'":
            close = _CLOSERS.get(c, "'")
            j = i + 1
            parts: list[str] = []
            while True:
                k = sql.find(close, j)
                if k < 0:
                    raise FormatError("unterminated quoted name in schema SQL")
                parts.append(sql[j:k])
                # A doubled quote is an escaped quote, except inside [...].
                if close != "]" and sql.startswith(close, k + 1):
                    parts.append(close)
                    j = k + 2
                    continue
                j = k + 1
                break
            tokens.append(Token("string" if c == "'" else "quoted", "".join(parts)))
            i = j
        else:
            tokens.append(Token("punct", c))
            i += 1
    return tokens


@dataclass(frozen=True, slots=True)
class ColumnDef:
    name: str
    declared_type: str
    affinity: str


@dataclass(frozen=True, slots=True)
class TableDef:
    columns: tuple[ColumnDef, ...]
    #: index into ``columns`` of the column aliasing the rowid, or ``None``.
    rowid_alias: int | None


@dataclass(frozen=True, slots=True)
class IndexDef:
    table: str
    columns: tuple[str, ...]
    unique: bool


_TYPE_STOPPERS = (
    "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT",
    "COLLATE", "REFERENCES", "GENERATED", "AS", "AUTOINCREMENT",
)  # fmt: skip
_TABLE_CONSTRAINT_STARTS = ("CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN")


def _skip_create_prefix(tokens: list[Token], what: str) -> int:
    """Position after ``CREATE [TEMP] <what> [IF NOT EXISTS] [schema.]name``."""
    i = 0
    if not (tokens and tokens[0].is_kw("CREATE")):
        raise FormatError("not a CREATE statement")
    i = 1
    if i < len(tokens) and tokens[i].is_kw("TEMP", "TEMPORARY"):
        i += 1
    if what == "INDEX" and i < len(tokens) and tokens[i].is_kw("UNIQUE"):
        i += 1
    if not (i < len(tokens) and tokens[i].is_kw(what)):
        raise FormatError(f"not a CREATE {what} statement")
    return i + 1


def _skip_if_not_exists(tokens: list[Token], i: int) -> int:
    if (
        i + 2 < len(tokens)
        and tokens[i].is_kw("IF")
        and tokens[i + 1].is_kw("NOT")
        and tokens[i + 2].is_kw("EXISTS")
    ):
        return i + 3
    return i


def _read_name(tokens: list[Token], i: int) -> tuple[str, int]:
    """Read ``[schema .] name`` and return the final name and next position."""
    if i >= len(tokens) or tokens[i].kind not in ("word", "quoted"):
        raise FormatError("expected a name")
    name = tokens[i].text
    i += 1
    if i + 1 < len(tokens) and tokens[i] == Token("punct", "."):
        if tokens[i + 1].kind not in ("word", "quoted"):
            raise FormatError("expected a name after '.'")
        name = tokens[i + 1].text
        i += 2
    return name, i


def _split_top_level(tokens: list[Token]) -> list[list[Token]]:
    """Split a token run at commas that are not nested inside parentheses."""
    items: list[list[Token]] = [[]]
    depth = 0
    for t in tokens:
        if t.kind == "punct":
            if t.text == "(":
                depth += 1
            elif t.text == ")":
                depth -= 1
            elif t.text == "," and depth == 0:
                items.append([])
                continue
        items[-1].append(t)
    return items


def _body(tokens: list[Token], i: int) -> list[Token]:
    """The tokens between the parenthesis at ``tokens[i]`` and its match."""
    if not (i < len(tokens) and tokens[i] == Token("punct", "(")):
        raise FormatError("expected '('")
    depth = 0
    for j in range(i, len(tokens)):
        t = tokens[j]
        if t.kind == "punct" and t.text == "(":
            depth += 1
        elif t.kind == "punct" and t.text == ")":
            depth -= 1
            if depth == 0:
                return tokens[i + 1 : j]
    raise FormatError("unbalanced parentheses")


def _top_level(tokens: list[Token]):
    """Yield ``(index, token)`` for tokens outside any parentheses."""
    depth = 0
    for k, t in enumerate(tokens):
        if t.kind == "punct" and t.text == "(":
            depth += 1
        elif t.kind == "punct" and t.text == ")":
            depth -= 1
        elif depth == 0:
            yield k, t


def parse_create_table(sql: str) -> TableDef:
    """Parse a ``CREATE TABLE`` statement into columns and rowid-alias info."""
    tokens = tokenize(sql)
    i = _skip_if_not_exists(tokens, _skip_create_prefix(tokens, "TABLE"))
    _, i = _read_name(tokens, i)
    items = _split_top_level(_body(tokens, i))

    columns: list[ColumnDef] = []
    column_pk: tuple[int, bool] | None = None  # (column index, followed by DESC)
    table_pk: str | None = None  # the single column of a table-level PRIMARY KEY
    for item in items:
        if not item:
            raise FormatError("empty item in CREATE TABLE")
        if item[0].is_kw(*_TABLE_CONSTRAINT_STARTS):
            pk = _table_primary_key(item)
            if pk is not None:
                table_pk = pk
            continue
        name_tok = item[0]
        if name_tok.kind not in ("word", "quoted"):
            raise FormatError("expected a column name")
        rest = item[1:]
        type_end = len(rest)
        for k, t in enumerate(rest):
            if t.is_kw(*_TYPE_STOPPERS):
                type_end = k
                break
        type_tokens = rest[:type_end]
        declared = " ".join(t.text for t in type_tokens)
        columns.append(ColumnDef(name_tok.text, declared, affinity_of(declared)))
        constraints = rest[type_end:]
        for k, t in _top_level(constraints):
            if t.is_kw("PRIMARY") and k + 1 < len(constraints) and constraints[k + 1].is_kw("KEY"):
                after = constraints[k + 2] if k + 2 < len(constraints) else None
                column_pk = (len(columns) - 1, after is not None and after.is_kw("DESC"))
                break

    alias: int | None = None
    if column_pk is not None and not column_pk[1]:
        alias = column_pk[0]
    elif table_pk is not None:
        folded = ascii_upper(table_pk)
        for idx, col in enumerate(columns):
            if ascii_upper(col.name) == folded:
                alias = idx
                break
    if alias is not None:
        col = columns[alias]
        if ascii_upper(col.declared_type) != "INTEGER":
            alias = None
    return TableDef(tuple(columns), alias)


def _table_primary_key(item: list[Token]) -> str | None:
    """Column name of ``[CONSTRAINT n] PRIMARY KEY (<one column>)``, else ``None``."""
    k = 0
    if item[0].is_kw("CONSTRAINT"):
        k = 2  # skip the keyword and the constraint's name
    if not (k + 1 < len(item) and item[k].is_kw("PRIMARY") and item[k + 1].is_kw("KEY")):
        return None
    cols = _split_top_level(_body(item, k + 2))
    if len(cols) != 1 or not cols[0] or cols[0][0].kind not in ("word", "quoted"):
        return None
    return cols[0][0].text


def parse_create_index(sql: str) -> IndexDef:
    """Parse a ``CREATE INDEX`` statement into its table and column names."""
    tokens = tokenize(sql)
    unique = len(tokens) > 1 and tokens[1].is_kw("UNIQUE")
    i = _skip_if_not_exists(tokens, _skip_create_prefix(tokens, "INDEX"))
    _, i = _read_name(tokens, i)
    if not (i < len(tokens) and tokens[i].is_kw("ON")):
        raise FormatError("expected ON")
    table, i = _read_name(tokens, i + 1)
    columns: list[str] = []
    for item in _split_top_level(_body(tokens, i)):
        if not item or item[0].kind not in ("word", "quoted"):
            raise FormatError("unsupported index column")
        columns.append(item[0].text)
    return IndexDef(table, tuple(columns), unique)
