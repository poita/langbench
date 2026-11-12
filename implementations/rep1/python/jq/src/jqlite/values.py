"""The jq data model: representation, ordering, equality and truthiness.

Python representation of jq values:

========  ===============================================
jq        Python
========  ===============================================
null      ``None``
boolean   ``bool``
number    ``float`` (always a float, never an ``int``)
string    ``str``
array     ``list`` (treated as immutable)
object    :class:`Obj` (insertion-ordered ``dict`` subclass, treated as immutable)
========  ===============================================

Values are shared, never deep-copied, and never mutated once built.
"""

from __future__ import annotations

from typing import Any


class Obj(dict):
    """An insertion-ordered jq object.

    It is a ``dict`` (insertion ordered, O(1) lookup) that additionally
    caches its code-point-sorted key list, so the keys of an object are
    sorted at most once however often ``keys`` or a comparison needs them.
    """

    __slots__ = ("_sorted_keys",)

    def sorted_keys(self) -> list[str]:
        try:
            return self._sorted_keys
        except AttributeError:
            keys = self._sorted_keys = sorted(self)
            return keys


def type_name(v: Any) -> str:
    """The jq ``type`` of a value."""
    if v is None:
        return "null"
    t = type(v)
    if t is bool:
        return "boolean"
    if t is float:
        return "number"
    if t is str:
        return "string"
    if t is list:
        return "array"
    return "object"


def is_true(v: Any) -> bool:
    """jq truthiness: only ``null`` and ``false`` are false."""
    return v is not None and v is not False


def sort_key(v: Any) -> tuple:
    """A key whose natural tuple ordering is jq's total order.

    ``null < false < true < numbers < strings < arrays < objects``; objects
    compare by sorted key list, then by the values in sorted key order.  Keys
    are hashable and two values are jq-equal exactly when their keys are equal.
    """
    t = type(v)
    if t is float:
        return (3, v)
    if t is str:
        return (4, v)
    if v is None:
        return (0,)
    if t is bool:
        return (2,) if v else (1,)
    if t is list:
        return (5, tuple([sort_key(x) for x in v]))
    keys = v.sorted_keys()
    return (6, tuple(keys), tuple([sort_key(v[k]) for k in keys]))


def equal(a: Any, b: Any) -> bool:
    """jq equality (object key order is irrelevant)."""
    t = type(a)
    if t is not type(b):
        return False
    if t is list:
        return len(a) == len(b) and all(equal(x, y) for x, y in zip(a, b))
    if t is Obj:
        if len(a) != len(b):
            return False
        for k, x in a.items():
            if k not in b or not equal(x, b[k]):
                return False
        return True
    return a == b


def compare(a: Any, b: Any) -> int:
    """Three-way comparison in jq order: -1, 0 or 1."""
    ka, kb = sort_key(a), sort_key(b)
    return (ka > kb) - (ka < kb)


def from_python(x: Any) -> Any:
    """Convert plain Python data (``dict``/``list``/``int``/...) to jq values."""
    if x is None or isinstance(x, (bool, str)):
        return x
    if isinstance(x, (int, float)):
        return float(x)
    if isinstance(x, (list, tuple)):
        return [from_python(i) for i in x]
    if isinstance(x, dict):
        return Obj((str(k), from_python(v)) for k, v in x.items())
    raise TypeError(f"cannot convert {type(x).__name__} to a jq value")


def to_python(v: Any) -> Any:
    """Convert jq values to plain Python data (integral numbers become ``int``)."""
    t = type(v)
    if t is float:
        return int(v) if v.is_integer() else v
    if t is list:
        return [to_python(x) for x in v]
    if t is Obj:
        return {k: to_python(x) for k, x in v.items()}
    return v
