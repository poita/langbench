"""Converting values to text: the *write* and *display* forms."""

from __future__ import annotations

from typing import Any

from . import bignum
from .values import NIL, VOID, Closure, Pair, Symbol, PrimitiveType

_WRITE_ESCAPES = str.maketrans({"\\": "\\\\", '"': '\\"', "\n": "\\n", "\t": "\\t"})


def _render(x: Any, out: list[str], display: bool) -> None:
    # Recursion is only on car fields; the cdr chain is walked iteratively.
    t = type(x)
    if t is int:
        out.append(str(x))
    elif t is bool:
        out.append("#t" if x else "#f")
    elif t is str:
        out.append(x if display else '"' + x.translate(_WRITE_ESCAPES) + '"')
    elif t is Symbol:
        out.append(x.name)
    elif t is Pair:
        out.append("(")
        while True:
            _render(x.car, out, display)
            x = x.cdr
            if type(x) is Pair:
                out.append(" ")
                continue
            if x is not NIL:
                out.append(" . ")
                _render(x, out, display)
            break
        out.append(")")
    elif x is NIL:
        out.append("()")
    elif x is VOID:
        out.append("#<void>")
    elif t is Closure or t is PrimitiveType:
        out.append("#<procedure>")
    elif t is bignum.BigInt:
        out.append(bignum.to_string(x))
    else:
        out.append(repr(x))


def write_string(x: Any) -> str:
    """The *write* form of ``x`` (strings quoted and escaped)."""
    out: list[str] = []
    _render(x, out, False)
    return "".join(out)


def display_string(x: Any) -> str:
    """The *display* form of ``x`` (strings raw)."""
    out: list[str] = []
    _render(x, out, True)
    return "".join(out)
