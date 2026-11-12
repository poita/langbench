"""The reader: turns program text into Scheme data.

The reader is iterative (it keeps its own stack), so arbitrarily deeply
nested input cannot exhaust the host stack.
"""

from __future__ import annotations

import re
from typing import Any, Iterator

from . import bignum
from .errors import SchemeSyntaxError
from .values import NIL, Pair, intern

_TOKEN = re.compile(
    r"""
    [ \t\r\n]+                         # whitespace
  | ;[^\n]*                            # comment
  | (?P<open>\()
  | (?P<close>\))
  | (?P<quote>')
  | "(?P<string>(?:[^"\\]|\\.)*)"      # string literal
  | (?P<atom>[^ \t\r\n()'";]+)         # symbol, number or boolean
    """,
    re.VERBOSE | re.DOTALL,
)
_INTEGER = re.compile(r"[+-]?[0-9]+\Z")
_ESCAPE = re.compile(r"\\(.)", re.DOTALL)
_ESCAPES = {"n": "\n", "t": "\t"}

_QUOTE = intern("quote")
_NO_TAIL = object()


def _unescape(m: "re.Match[str]") -> str:
    c = m.group(1)
    return _ESCAPES.get(c, c)


def parse_atom(token: str) -> Any:
    """Convert a bare token to an integer, boolean or symbol."""
    if token == "#t":
        return True
    if token == "#f":
        return False
    if _INTEGER.match(token):
        digits = token.lstrip("+-")
        if len(digits) <= 18:  # < 10**18 < 2**62: a machine word
            return int(token)
        return bignum.parse(token)
    return intern(token)


class _Frame:
    """An open list being read."""

    __slots__ = ("items", "tail", "after_dot", "quotes")

    def __init__(self) -> None:
        self.items: list[Any] = []
        self.tail: Any = _NO_TAIL
        self.after_dot = False
        self.quotes = 0  # pending ' prefixes for the next datum


def read_iter(source: str) -> Iterator[Any]:
    """Yield the top-level datums of ``source`` one at a time."""
    pos = 0
    end = len(source)
    stack: list[_Frame] = []
    top = _Frame()  # the implicit top-level "list"
    match = _TOKEN.match
    while pos < end:
        m = match(source, pos)
        if m is None:
            raise SchemeSyntaxError(f"unexpected character at offset {pos}")
        pos = m.end()
        kind = m.lastgroup
        if kind is None:
            continue  # whitespace or comment
        if kind == "open":
            stack.append(top)
            top = _Frame()
            continue
        if kind == "quote":
            top.quotes += 1
            continue
        if kind == "close":
            if not stack:
                raise SchemeSyntaxError("unbalanced close parenthesis")
            if top.quotes or top.after_dot and top.tail is _NO_TAIL:
                raise SchemeSyntaxError("malformed list")
            tail = NIL if top.tail is _NO_TAIL else top.tail
            datum = _build(top.items, tail)
            top = stack.pop()
        elif kind == "string":
            datum = _ESCAPE.sub(_unescape, m.group("string"))
        else:
            token = m.group("atom")
            if token == "." and stack:
                top.after_dot = True
                continue
            datum = parse_atom(token)
        while top.quotes:
            top.quotes -= 1
            datum = Pair(_QUOTE, Pair(datum, NIL))
        if top.after_dot:
            top.tail = datum
        elif stack:
            top.items.append(datum)
        else:
            yield datum
    if stack or top.quotes:
        raise SchemeSyntaxError("unexpected end of input")


def _build(items: list[Any], tail: Any) -> Any:
    result = tail
    for item in reversed(items):
        result = Pair(item, result)
    return result


def read_all(source: str) -> list[Any]:
    """Read every datum in ``source`` and return them as a list."""
    return list(read_iter(source))
