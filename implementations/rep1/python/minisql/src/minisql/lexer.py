"""Tokenizer: turns a SQL script into one token list per statement."""

from __future__ import annotations

import re
from typing import NamedTuple

KEYWORDS = frozenset(
    """SELECT FROM WHERE AND OR NOT NULL IS LIKE AS INSERT INTO VALUES DELETE
    UPDATE SET CREATE TABLE INTEGER TEXT INNER JOIN ON GROUP BY HAVING ORDER
    ASC DESC LIMIT OFFSET LEFT RIGHT FULL OUTER CROSS NATURAL""".split()
)


class Token(NamedTuple):
    """A lexical token.

    ``kind`` is one of ``kw`` (value upper-cased), ``ident`` (value
    lower-cased), ``int`` (value an ``int``), ``str`` (value the unescaped
    text), ``op`` (value the operator, with ``==`` normalised to ``=`` and
    ``<>`` to ``!=``), ``invalid`` or ``eof``.
    """

    kind: str
    value: object


EOF_TOKEN = Token("eof", None)

_TOKEN_RE = re.compile(
    r"""
      (?P<ws>[ \t\r\n\f\v]+|--[^\n]*)
    | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
    | (?P<int>[0-9]+)
    | (?P<str>'[^']*(?:''[^']*)*')
    | (?P<op><=|>=|<>|!=|==|[-+*/%=<>(),.;])
    """,
    re.VERBOSE,
)

_OP_ALIASES = {"==": "=", "<>": "!="}


def split_statements(text: str) -> list[list[Token]]:
    """Tokenize ``text`` and split it into statements on ``;`` tokens.

    Empty statements are dropped. A character that is not part of any valid
    token becomes an ``invalid`` token (so the statement containing it fails to
    parse, while later statements are unaffected). An unterminated string
    literal swallows the rest of the input into a single invalid token.
    """
    statements: list[list[Token]] = []
    current: list[Token] = []
    pos = 0
    end = len(text)
    match = _TOKEN_RE.match
    while pos < end:
        m = match(text, pos)
        if m is None:
            # Unterminated string literal: it extends to the end of input.
            if text[pos] == "'":
                current.append(Token("invalid", "'"))
                break
            current.append(Token("invalid", text[pos]))
            pos += 1
            continue
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        raw = m.group()
        if kind == "ident":
            upper = raw.upper()
            if upper in KEYWORDS:
                current.append(Token("kw", upper))
            else:
                current.append(Token("ident", raw.lower()))
        elif kind == "int":
            current.append(Token("int", int(raw)))
        elif kind == "str":
            current.append(Token("str", raw[1:-1].replace("''", "'")))
        elif raw == ";":
            if current:
                statements.append(current)
                current = []
        else:
            current.append(Token("op", _OP_ALIASES.get(raw, raw)))
    if current:
        statements.append(current)
    return statements
