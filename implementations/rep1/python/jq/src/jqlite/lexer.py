"""Tokenizer for filter text."""

from __future__ import annotations

import re

from .errors import JQSyntaxError
from .jsonio import unescape

_TOKEN = re.compile(
    r"""[ \t\r\n]*(?:
      (?P<num>[0-9]+(?:\.[0-9]+)?)
    | (?P<str>"(?:[^"\\]|\\.)*")
    | (?P<field>\.[A-Za-z_][A-Za-z0-9_]*)
    | (?P<var>\$[A-Za-z_][A-Za-z0-9_]*)
    | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
    | (?P<op>==|!=|<=|>=|[-+*/%<>.,|:;()\[\]{}?=])
    | (?P<end>$)
    )""",
    re.X | re.S,
)

# Token kinds: num, str, field, var, ident, op, end.  ``value`` is the parsed
# number, decoded string, name (without ``.``/``$``) or operator text.
Token = tuple[str, object]


def tokenize(source: str) -> list[Token]:
    """Split a filter into tokens; the list always ends with an ``end`` token."""
    tokens: list[Token] = []
    pos = 0
    n = len(source)
    while True:
        m = _TOKEN.match(source, pos)
        if m is None:
            raise JQSyntaxError(f"unexpected character {source[pos:].strip()[:1]!r}")
        kind = m.lastgroup
        text = m.group(kind)
        pos = m.end()
        if kind == "end":
            if pos < n:
                raise JQSyntaxError("unexpected input")
            tokens.append(("end", ""))
            return tokens
        if kind == "num":
            tokens.append(("num", float(text)))
        elif kind == "str":
            try:
                tokens.append(("str", unescape(text[1:-1])))
            except ValueError as exc:
                raise JQSyntaxError(str(exc)) from None
        elif kind == "field" or kind == "var":
            tokens.append((kind, text[1:]))
        else:
            tokens.append((kind, text))
