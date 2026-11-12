"""Tokeniser."""

from __future__ import annotations

import re
from typing import NamedTuple

from .errors import ParseError

KEYWORDS = frozenset({"let", "rec", "in", "fun", "if", "then", "else", "true", "false"})

# Token kinds: "int", "ident", "eof", or the text of a keyword / symbol itself.
INT = "int"
IDENT = "ident"
EOF = "eof"


class Token(NamedTuple):
    kind: str
    text: str
    pos: int


_TOKEN = re.compile(
    r"""
    (?P<ws>[ \t\r\n]+)
  | (?P<int>[0-9]+)
  | (?P<word>[a-z][A-Za-z0-9_]*)
  | (?P<sym>;;|->|::|<=|>=|&&|\|\||[()\[\];,+\-*/=<>])
    """,
    re.VERBOSE,
)


def tokenize(source: str) -> list[Token]:
    """Split ``source`` into tokens, ending with an ``eof`` token."""
    tokens: list[Token] = []
    append = tokens.append
    pos = 0
    n = len(source)
    match = _TOKEN.match
    while pos < n:
        m = match(source, pos)
        if m is None:
            raise ParseError(f"unexpected character {source[pos]!r}", pos)
        kind = m.lastgroup
        if kind != "ws":
            text = m.group()
            if kind == "word":
                append(Token(text if text in KEYWORDS else IDENT, text, pos))
            elif kind == "int":
                append(Token(INT, text, pos))
            else:
                append(Token(text, text, pos))
        pos = m.end()
    append(Token(EOF, "", n))
    return tokens
