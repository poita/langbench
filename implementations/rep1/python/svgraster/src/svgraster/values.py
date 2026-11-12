"""Parsers for numbers, lengths, opacities, number lists and ``style`` text."""

from __future__ import annotations

import re

__all__ = [
    "NUMBER_RE",
    "match_number",
    "parse_length",
    "parse_number_list",
    "parse_opacity",
    "parse_style",
]

NUMBER_RE = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")
_SEPARATED = re.compile(r"[\s,]*(" + NUMBER_RE.pattern + ")")


def match_number(text: str, pos: int = 0) -> tuple[float, int] | None:
    """Match a number at *pos*; return ``(value, end)`` or ``None``."""
    m = NUMBER_RE.match(text, pos)
    if m is None:
        return None
    return float(m.group()), m.end()


def parse_length(text: str | None) -> float | None:
    """Parse a length (a number, optionally followed by ``px``).

    Returns ``None`` when the text does not start with a number.
    """
    if text is None:
        return None
    m = NUMBER_RE.match(text.lstrip())
    if m is None:
        return None
    return float(m.group())


def parse_number_list(text: str | None) -> list[float]:
    """Parse numbers separated by whitespace and/or commas.

    Parsing stops at the first thing that is not a number.
    """
    out: list[float] = []
    if not text:
        return out
    pos = 0
    n = len(text)
    while pos < n:
        m = _SEPARATED.match(text, pos)
        if m is None:
            break
        out.append(float(m.group(1)))
        pos = m.end()
    return out


def parse_opacity(text: str | None) -> float | None:
    """Parse an opacity (``0.5`` or ``50%``), clamped to ``[0, 1]``.

    Returns ``None`` if the value is not of that form.
    """
    if text is None:
        return None
    s = text.strip()
    m = NUMBER_RE.match(s)
    if m is None:
        return None
    rest = s[m.end():]
    value = float(m.group())
    if rest == "%":
        value /= 100.0
    elif rest != "":
        return None
    return min(1.0, max(0.0, value))


def parse_style(text: str | None) -> dict[str, str]:
    """Parse a ``style`` attribute into ``{lower-case name: value}``.

    Declarations without a ``:`` and declarations with an empty value are
    ignored; later declarations override earlier ones.
    """
    out: dict[str, str] = {}
    if not text:
        return out
    for decl in text.split(";"):
        name, sep, value = decl.partition(":")
        if not sep:
            continue
        name = name.strip().lower()
        value = value.strip()
        if name and value:
            out[name] = value
    return out
