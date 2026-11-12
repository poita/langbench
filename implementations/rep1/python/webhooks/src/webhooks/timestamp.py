"""Canonical decimal integers, as used for timestamps."""

from __future__ import annotations

import re

__all__ = ["MAX_TIMESTAMP", "is_canonical_int", "parse_canonical_int"]

MAX_TIMESTAMP = 10**15

_CANONICAL = re.compile(rb"0|-?[1-9][0-9]{0,15}")


def _as_bytes(text: str | bytes) -> bytes:
    return text if isinstance(text, bytes) else text.encode("utf-8")


def parse_canonical_int(text: str | bytes) -> int | None:
    """Return the integer *text* denotes, or ``None`` if it is not canonical.

    Canonical means ``0``, or an optional ``-`` followed by digits with no
    leading zero, with absolute value at most 10**15.
    """
    raw = _as_bytes(text)
    if _CANONICAL.fullmatch(raw) is None:
        return None
    value = int(raw)
    return value if abs(value) <= MAX_TIMESTAMP else None


def is_canonical_int(text: str | bytes) -> bool:
    """True if *text* is a canonical decimal integer within bounds."""
    return parse_canonical_int(text) is not None
