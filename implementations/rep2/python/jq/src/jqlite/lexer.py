"""Tokenizer for filter text."""

from __future__ import annotations

import re
from typing import List, NamedTuple

from .errors import JQSyntaxError
from .jsonio import JSONDecodeError, unescape


class Token(NamedTuple):
    kind: str  # num str field var ident op eof
    value: object
    pos: int


_TOKEN = re.compile(
    r"""(?P<ws>[ \t\r\n]+)
      | (?P<num>[0-9]+(?:\.[0-9]+)?)
      | "(?P<str>[^"\\]*(?:\\.[^"\\]*)*)"
      | (?P<field>\.[A-Za-z_][A-Za-z0-9_]*)
      | \$[ \t]*(?P<var>[A-Za-z_][A-Za-z0-9_]*)
      | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
      | (?P<op>==|!=|<=|>=|[-+*/%<>=|,:;.?()\[\]{}])
    """,
    re.X | re.S,
)


def tokenize(text: str) -> List[Token]:
    """Split ``text`` into tokens (whitespace dropped, ``eof`` appended)."""
    tokens: List[Token] = []
    pos, n = 0, len(text)
    match = _TOKEN.match
    while pos < n:
        m = match(text, pos)
        if m is None:
            raise JQSyntaxError(f"unexpected character {text[pos]!r} at offset {pos}")
        kind = m.lastgroup
        if kind != "ws":
            if kind == "num":
                tokens.append(Token("num", float(m.group()), pos))
            elif kind == "str":
                try:
                    tokens.append(Token("str", unescape(m.group("str")), pos))
                except JSONDecodeError as e:
                    raise JQSyntaxError(f"bad string literal at offset {pos}: {e}") from None
            elif kind == "field":
                tokens.append(Token("field", m.group()[1:], pos))
            else:
                tokens.append(Token(kind, m.group(kind), pos))
        pos = m.end()
    tokens.append(Token("eof", None, n))
    return tokens
