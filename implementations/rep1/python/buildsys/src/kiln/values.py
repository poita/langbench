"""KBL values.

A KBL value is represented by a native Python object:

========  ==============
KBL type  Python type
========  ==============
``str``   ``bytes``
``int``   ``int`` (kept within signed 64 bits by :func:`wrap`)
``bool``  ``bool``
``list``  ``list`` (never mutated once built, so sharing is safe)
========  ==============

Python treats ``True == 1``; KBL does not, so comparisons go through
:func:`values_equal` and :func:`sort_key` instead of ``==`` and ``<``.
"""

from __future__ import annotations

from typing import Any

from .errors import KilnError

Value = Any

_TYPE_NAMES = {bytes: "str", int: "int", bool: "bool", list: "list"}
_RANK = {bool: 0, int: 1, bytes: 2, list: 3}

INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1


def type_name(value: Value) -> str:
    """The KBL type token of *value*: ``str``, ``int``, ``bool`` or ``list``."""
    return _TYPE_NAMES[type(value)]


def wrap(n: int) -> int:
    """Wrap *n* to a signed 64-bit two's-complement integer."""
    if INT_MIN <= n <= INT_MAX:
        return n
    return ((n + (1 << 63)) & ((1 << 64) - 1)) - (1 << 63)


def values_equal(a: Value, b: Value) -> bool:
    """Deep structural equality; values of different types are never equal."""
    ta = type(a)
    if ta is not type(b):
        return False
    if ta is list:
        if len(a) != len(b):
            return False
        for x, y in zip(a, b):
            if not values_equal(x, y):
                return False
        return True
    return a == b


def sort_key(value: Value) -> tuple:
    """A key realising the total order ``bool < int < str < list``."""
    t = type(value)
    if t is list:
        return (3, tuple([sort_key(v) for v in value]))
    if t is bool:
        return (0, int(value))
    return (_RANK[t], value)


def hashable_key(value: Value) -> Any:
    """A hashable stand-in such that keys are equal iff the values are equal."""
    t = type(value)
    if t is list:
        return ("l", tuple([hashable_key(v) for v in value]))
    if t is bool:
        return ("b", value)
    return value


def interpolate(value: Value) -> bytes:
    """Text contributed by an interpolation (or ``str()``) of *value*."""
    t = type(value)
    if t is bytes:
        return value
    if t is int:
        return b"%d" % value
    if t is bool:
        return b"true" if value else b"false"
    raise KilnError("E_INTERP", "list")
