"""S-expression reader and canonical printer (SPEC section 5.1 and 23.4).

Values produced by :func:`parse`:

* ``int`` for integer atoms (which must fit in a signed 64-bit integer),
* :class:`Symbol` (a ``str`` subclass) for every other atom,
* :class:`String` (a ``str`` subclass, quotes removed) for string literals,
* ``list`` for parenthesised lists.
"""

from __future__ import annotations

import re
from typing import Any

from .errors import DatabaseError

__all__ = ["Symbol", "String", "parse", "render"]


class Symbol(str):
    """A bare atom that is not an integer."""

    __slots__ = ()


class String(str):
    """A double-quoted string literal (contents only)."""

    __slots__ = ()


_TOKEN = re.compile(
    r"""
    (?P<ws>[ \t\r\n\f\v]+)
  | (?P<comment>;[^\n]*)
  | (?P<open>\()
  | (?P<close>\))
  | "(?P<string>[^"\n]*)"
  | (?P<atom>[^ \t\r\n\f\v();"]+)
    """,
    re.VERBOSE,
)
_INT = re.compile(r"-?[0-9]+\Z")
_I64_MIN = -(1 << 63)
_I64_MAX = (1 << 63) - 1


def parse(text: str) -> list[Any]:
    """Parse *text* into a list of top-level s-expressions.

    Raises :class:`DatabaseError` for unbalanced parentheses, unterminated
    strings and out-of-range integers.
    """
    stack: list[list[Any]] = [[]]
    pos = 0
    n = len(text)
    match = _TOKEN.match
    while pos < n:
        m = match(text, pos)
        if m is None:
            raise DatabaseError("cannot tokenise at offset %d" % pos)
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws" or kind == "comment":
            continue
        if kind == "open":
            stack.append([])
        elif kind == "close":
            if len(stack) == 1:
                raise DatabaseError("unbalanced ')'")
            done = stack.pop()
            stack[-1].append(done)
        elif kind == "string":
            stack[-1].append(String(m.group("string")))
        else:
            atom = m.group("atom")
            if _INT.match(atom):
                value = int(atom)
                if not _I64_MIN <= value <= _I64_MAX:
                    raise DatabaseError("integer out of range: " + atom)
                stack[-1].append(value)
            else:
                stack[-1].append(Symbol(atom))
    if len(stack) != 1:
        raise DatabaseError("unbalanced '('")
    return stack[0]


def render(x: Any) -> str:
    """Canonical printing: single spaces, no other whitespace."""
    if isinstance(x, list):
        return "(" + " ".join(render(e) for e in x) + ")"
    if isinstance(x, String):
        return '"' + x + '"'
    return str(x)
