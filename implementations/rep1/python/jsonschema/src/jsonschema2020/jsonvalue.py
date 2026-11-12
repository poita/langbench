"""The JSON data model used throughout the library.

JSON values are represented with plain Python objects:

=========  ===========================================================
JSON       Python
=========  ===========================================================
null       ``None``
boolean    ``bool``
number     ``int`` when the value is whole, otherwise ``fractions.Fraction``
string     ``str`` (a sequence of code points)
array      ``list``
object     ``dict`` (insertion ordered)
=========  ===========================================================

Numbers are *exact*: a literal such as ``0.1`` is the rational ``1/10`` and
binary floating point is never involved.  Because ``int`` and ``Fraction``
hash and compare consistently, ``1``, ``1.0`` and ``1e0`` all become the same
Python ``int``.

Beware that ``bool`` is a subclass of ``int`` in Python; always test
``type(value) is bool`` (or use :func:`json_type`) before treating a value as
a number.
"""

from __future__ import annotations

from fractions import Fraction
from typing import Any

__all__ = [
    "JSON_NULL",
    "json_type",
    "is_number",
    "is_integer",
    "json_equal",
    "freeze",
    "normalize",
]

JSON_NULL = None

_TYPE_NAMES = {
    type(None): "null",
    bool: "boolean",
    int: "number",
    Fraction: "number",
    str: "string",
    list: "array",
    dict: "object",
}


def json_type(value: Any) -> str:
    """Return the JSON type name of *value*.

    Whole numbers are reported as ``"number"``; use :func:`is_integer` to tell
    whether a number is an integer.
    """
    try:
        return _TYPE_NAMES[type(value)]
    except KeyError:
        raise TypeError(f"not a JSON value: {value!r}") from None


def is_number(value: Any) -> bool:
    """True for JSON numbers (``bool`` is *not* a number)."""
    t = type(value)
    return t is int or t is Fraction


def is_integer(value: Any) -> bool:
    """True when *value* is a JSON number denoting a whole number."""
    t = type(value)
    return t is int or (t is Fraction and value.denominator == 1)


def freeze(value: Any) -> Any:
    """Return a hashable key such that ``freeze(a) == freeze(b)`` iff ``a`` and
    ``b`` are JSON-equal (spec section 3.4).

    The key is built so that values of different JSON types can never collide:
    strings and numbers stand for themselves, everything else is tagged.
    """
    t = type(value)
    if t is str or t is int or t is Fraction:
        return value
    if t is bool:
        return ("b", value)
    if value is None:
        return ("z",)
    if t is list:
        return ("l", tuple([freeze(v) for v in value]))
    if t is dict:
        return ("o", frozenset([(k, freeze(v)) for k, v in value.items()]))
    raise TypeError(f"not a JSON value: {value!r}")


def json_equal(a: Any, b: Any) -> bool:
    """Structural JSON equality (spec section 3.4)."""
    ta = type(a)
    tb = type(b)
    if ta is bool or tb is bool:
        return ta is tb and a == b
    if ta is str or tb is str:
        return ta is tb and a == b
    if ta is list:
        if tb is not list or len(a) != len(b):
            return False
        for x, y in zip(a, b):
            if not json_equal(x, y):
                return False
        return True
    if ta is dict:
        if tb is not dict or len(a) != len(b):
            return False
        for k, x in a.items():
            if k not in b or not json_equal(x, b[k]):
                return False
        return True
    if a is None or b is None:
        return a is b
    # Remaining case: int / Fraction on both sides.
    return ta in (int, Fraction) and tb in (int, Fraction) and a == b


def normalize(value: Any) -> Any:
    """Convert an arbitrary Python structure into the library's data model.

    Useful when instances come from somewhere other than
    :func:`jsonschema2020.loads`, e.g. the standard ``json`` module.  Floats
    become exact decimals (via their shortest ``repr``), tuples become lists and
    integral ``Fraction`` values become ``int``.
    """
    t = type(value)
    if t is str or t is bool or value is None or t is int:
        return value
    if t is Fraction:
        return value.numerator if value.denominator == 1 else value
    if t is float:
        if value != value or value in (float("inf"), float("-inf")):
            raise ValueError("NaN and infinity are not JSON numbers")
        f = Fraction(repr(value))
        return f.numerator if f.denominator == 1 else f
    if t is list or t is tuple:
        return [normalize(v) for v in value]
    if t is dict:
        return {str(k): normalize(v) for k, v in value.items()}
    raise TypeError(f"cannot convert {value!r} to a JSON value")
