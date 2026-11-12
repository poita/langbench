"""Integer and float literals: parsing and canonical formatting."""

from __future__ import annotations

import re

_DEC = r"[+-]?(?:0|[1-9](?:_?[0-9])*)"
_EXP = r"[eE][+-]?[0-9](?:_?[0-9])*"
_FRAC = r"\.[0-9](?:_?[0-9])*"

_DEC_INT = re.compile(_DEC)
_HEX_INT = re.compile(r"0x[0-9a-fA-F](?:_?[0-9a-fA-F])*")
_OCT_INT = re.compile(r"0o[0-7](?:_?[0-7])*")
_BIN_INT = re.compile(r"0b[01](?:_?[01])*")
_FLOAT = re.compile(rf"{_DEC}(?:{_FRAC}(?:{_EXP})?|{_EXP})")
_SPECIAL = re.compile(r"([+-]?)(inf|nan)")

INT_MIN = -(2**63)
INT_MAX = 2**63 - 1


def parse_integer(token: str) -> str | None:
    """Return the canonical decimal text of an integer literal.

    Returns ``None`` if *token* is not a valid TOML integer or if it does not
    fit in a signed 64-bit integer.
    """
    if _DEC_INT.fullmatch(token):
        digits = token.replace("_", "")
        if len(digits) > 21:  # cannot fit; also avoids int()'s digit limit
            return None
        value = int(digits)
    elif _HEX_INT.fullmatch(token):
        value = int(token[2:].replace("_", ""), 16)
    elif _OCT_INT.fullmatch(token):
        value = int(token[2:].replace("_", ""), 8)
    elif _BIN_INT.fullmatch(token):
        value = int(token[2:].replace("_", ""), 2)
    else:
        return None
    if value < INT_MIN or value > INT_MAX:
        return None
    return str(value)


def format_float(x: float) -> str:
    """Canonical text of a double: ``%.16e`` for finite values, else ``inf``/``-inf``/``nan``."""
    if x != x:
        return "nan"
    if x == float("inf"):
        return "inf"
    if x == float("-inf"):
        return "-inf"
    return "%.16e" % x


def parse_float(token: str) -> str | None:
    """Return the canonical text of a float literal, or ``None`` if invalid.

    Conversion is correctly rounded; overflow gives infinity and underflow
    gives zero, as with ``strtod``.
    """
    if _FLOAT.fullmatch(token):
        return format_float(float(token.replace("_", "")))
    m = _SPECIAL.fullmatch(token)
    if m:
        if m.group(2) == "nan":
            return "nan"
        return "-inf" if m.group(1) == "-" else "inf"
    return None
