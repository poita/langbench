"""Canonical text form: render a :class:`~protowire.values.Message` tree."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .scalars import BOOL, BYTES, INT, STRING
from .values import Message

_ESCAPES = {ord('"'): '\\"', ord("\\"): "\\\\", ord("\n"): "\\n", ord("\r"): "\\r", ord("\t"): "\\t"}
for _c in [*range(0x20), 0x7F]:
    _ESCAPES.setdefault(_c, f"\\x{_c:02x}")
_STRING_TABLE = str.maketrans(_ESCAPES)


def _format_string(s: str) -> str:
    return '"' + s.translate(_STRING_TABLE) + '"'


def _format_bytes(b: bytes) -> str:
    return 'x"' + b.hex() + '"'


def _format_bool(v: bool) -> str:
    return "true" if v else "false"


_FORMATTERS: dict[str, Callable[[Any], str]] = {
    INT: str,
    BOOL: _format_bool,
    STRING: _format_string,
    BYTES: _format_bytes,
}


def format_message(msg: Message) -> str:
    """Render ``msg`` in the canonical text form.

    Fields appear in increasing field-number order; scalars equal to their
    default and empty lists are omitted; present sub-messages are always shown.
    """
    out: list[str] = []
    _render(msg, out)
    return "".join(out)


def _render(msg: Message, out: list[str]) -> None:
    out.append("{")
    by_number = msg.desc.by_number
    values = msg.values
    first = True
    for number in sorted(values):
        fd = by_number[number]
        v = values[number]
        scalar = fd.scalar
        if fd.repeated:
            if not v:
                continue
        elif scalar is not None and not v:
            continue
        if first:
            first = False
        else:
            out.append(", ")
        out.append(fd.name + ": ")
        if scalar is None:
            if fd.repeated:
                out.append("[")
                for i, sub in enumerate(v):
                    if i:
                        out.append(", ")
                    _render(sub, out)
                out.append("]")
            else:
                _render(v, out)
        else:
            fmt = _FORMATTERS[scalar.category]
            if fd.repeated:
                out.append("[" + ", ".join(map(fmt, v)) + "]")
            else:
                out.append(fmt(v))
    out.append("}")
