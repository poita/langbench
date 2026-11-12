"""Tokeniser for Datalog source text."""

from __future__ import annotations

import re
from typing import Iterator, NamedTuple

from .errors import ParseError

# Token kinds
IDENT = "ident"
VAR = "var"
ANON = "anon"
INT = "int"
NOT = "not"
PUNCT = "punct"

# Alternatives are tried in order, so longer operators precede their prefixes
# (``:-`` before a negative integer, ``<=`` before ``<``).
_TOKEN_RE = re.compile(
    r"""
    (?P<skip>(?:\s+|%[^\n]*)+)
  | (?P<punct>:-|\?-|<=|>=|!=|[<>=(),.])
  | (?P<int>-?[0-9]+)
  | (?P<ident>[a-z][a-z0-9_]*)
  | (?P<var>[A-Z][A-Za-z0-9_]*)
  | (?P<anon>_)
    """,
    re.VERBOSE,
)


class Token(NamedTuple):
    kind: str
    text: str
    pos: int


def tokenize(source: str) -> Iterator[Token]:
    """Yield the tokens of ``source``; whitespace and ``%`` comments are skipped.

    Raises :class:`ParseError` on a character that starts no token.
    """
    match = _TOKEN_RE.match
    pos = 0
    end = len(source)
    while pos < end:
        m = match(source, pos)
        if m is None:
            raise ParseError(f"unexpected character {source[pos]!r} at offset {pos}")
        kind = m.lastgroup
        if kind != "skip":
            text = m.group()
            if kind == IDENT and text == "not":
                kind = NOT
            yield Token(kind, text, pos)  # type: ignore[arg-type]
        pos = m.end()
