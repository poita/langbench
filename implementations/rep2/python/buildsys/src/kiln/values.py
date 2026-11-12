"""KBL values and their operations.

KBL values are represented by plain Python objects:

========  ==================
KBL type  Python type
========  ==================
``str``   ``bytes``
``int``   ``int``
``bool``  ``bool``
``list``  ``list``
========  ==================

Beware that ``bool`` is a subclass of ``int`` in Python, so every type test
here uses ``type(v) is ...`` rather than ``isinstance``.  Lists are treated as
immutable once created, which makes "copying" one an O(1) aliasing.
"""

from __future__ import annotations

from typing import Any

from .errors import KilnError

__all__ = ["type_name", "sort_key", "equal", "stringify", "wrap_int", "INT_MIN", "INT_MAX"]

INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1


def type_name(value: Any) -> str:
    """The KBL type token of ``value``: ``str``, ``int``, ``bool`` or ``list``."""
    t = type(value)
    if t is bytes:
        return "str"
    if t is bool:
        return "bool"
    if t is int:
        return "int"
    return "list"


def sort_key(value: Any) -> tuple:
    """A key realising the total order: bool < int < str < list.

    Lists compare element by element, shorter-is-smaller on a common prefix,
    which is exactly Python's tuple ordering.
    """
    t = type(value)
    if t is bytes:
        return (2, value)
    if t is int:
        return (1, value)
    if t is bool:
        return (0, value)
    return (3, tuple([sort_key(v) for v in value]))


def equal(a: Any, b: Any) -> bool:
    """Deep structural equality; values of different types are never equal."""
    ta = type(a)
    if ta is not type(b):
        return False
    if ta is list:
        if len(a) != len(b):
            return False
        for x, y in zip(a, b):
            if not equal(x, y):
                return False
        return True
    return a == b


def stringify(value: Any) -> bytes:
    """The text of a str, int or bool (as produced by interpolation).

    Raises ``E_INTERP`` for a list.
    """
    t = type(value)
    if t is bytes:
        return value
    if t is int:
        return b"%d" % value
    if t is bool:
        return b"true" if value else b"false"
    raise KilnError("E_INTERP", b"list")


def wrap_int(n: int) -> int:
    """Wrap ``n`` into the signed 64-bit range."""
    if INT_MIN <= n <= INT_MAX:
        return n
    return ((n + (1 << 63)) & ((1 << 64) - 1)) - (1 << 63)
