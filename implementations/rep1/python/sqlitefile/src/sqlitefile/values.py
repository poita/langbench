"""SQL values: ordering, type affinity and text output (spec Parts 2.3, 3, 5)."""

from __future__ import annotations

import re
from typing import Any

from .record import Value

INTEGER = "INTEGER"
TEXT = "TEXT"
BLOB = "BLOB"
REAL = "REAL"
NUMERIC = "NUMERIC"

_INT64_MIN = -(1 << 63)
_INT64_MAX = (1 << 63) - 1


def ascii_lower(s: str) -> str:
    """Lower-case ASCII letters only, as SQLite's identifier folding does."""
    return s.translate(_ASCII_LOWER)


_ASCII_LOWER = {c: c + 32 for c in range(ord("A"), ord("Z") + 1)}


def affinity_of(declared_type: str) -> str:
    """Column affinity from a declared type, by the five ordered rules of §2.3."""
    t = ascii_upper(declared_type)
    if "INT" in t:
        return INTEGER
    if "CHAR" in t or "CLOB" in t or "TEXT" in t:
        return TEXT
    if "BLOB" in t or not t:
        return BLOB
    if "REAL" in t or "FLOA" in t or "DOUB" in t:
        return REAL
    return NUMERIC


def ascii_upper(s: str) -> str:
    return s.translate(_ASCII_UPPER)


_ASCII_UPPER = {c: c - 32 for c in range(ord("a"), ord("z") + 1)}


# --- ordering ---------------------------------------------------------------


def sort_key(v: Value) -> tuple[int, Any]:
    """A key that orders values by the storage-class rules of Part 3.

    NULL < numbers < TEXT < BLOB. Integers and floats compare by exact
    mathematical value (Python compares them exactly), TEXT by code point,
    which equals unsigned UTF-8 byte order, and BLOB bytewise.
    """
    if v is None:
        return (0, 0)
    if isinstance(v, (int, float)):
        return (1, v)
    if isinstance(v, str):
        return (2, v)
    return (3, v)


def compare(a: Value, b: Value) -> int:
    """Three-way comparison of two values: -1, 0 or 1."""
    ka, kb = sort_key(a), sort_key(b)
    return -1 if ka < kb else (1 if ka > kb else 0)


# --- affinity applied to a query literal --------------------------------------

_NUMERIC_CONSTANT = re.compile(
    r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", re.ASCII
)


def parse_numeric_constant(text: str) -> int | float | None:
    """Parse ``text`` as a numeric constant (§3), or return ``None``.

    Spaces and tabs around the number are ignored. The result is an ``int``
    when the text has no ``.`` or exponent and fits in 64 bits, else a float.
    """
    s = text.strip(" \t")
    if not _NUMERIC_CONSTANT.fullmatch(s):
        return None
    if "." not in s and "e" not in s and "E" not in s:
        n = int(s)
        if _INT64_MIN <= n <= _INT64_MAX:
            return n
    return float(s)


def apply_affinity(literal: Value, affinity: str) -> Value:
    """Convert a query literal according to the column it is compared against."""
    if affinity == TEXT:
        if isinstance(literal, float):
            return format_real(literal)
        if isinstance(literal, int):
            return str(literal)
    elif affinity in (INTEGER, REAL, NUMERIC) and isinstance(literal, str):
        number = parse_numeric_constant(literal)
        if number is not None:
            return number
    return literal


# --- output -------------------------------------------------------------------


def format_real(v: float) -> str:
    """Format a float like C's ``%.15g``, always with a ``.`` in the mantissa."""
    if v != v:
        return "NaN"
    if v in (float("inf"), float("-inf")):
        return "Inf" if v > 0 else "-Inf"
    if v == 0:
        return "0.0"
    s = "%.15g" % v
    mantissa, e, exponent = s.partition("e")
    if "." not in mantissa:
        mantissa += ".0"
    return mantissa + e + exponent


def format_value(v: Value) -> str:
    """Render a value the way the sqlite3 shell does (§5)."""
    if v is None:
        return "NULL"
    if isinstance(v, str):
        return v
    if isinstance(v, float):
        return format_real(v)
    if isinstance(v, int):
        return str(v)
    return v.hex().upper()
