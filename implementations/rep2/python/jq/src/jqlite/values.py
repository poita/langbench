"""The jq data model and its ordering.

Values are represented with native Python types:

=========  ====================================================
jq         Python
=========  ====================================================
null       ``None``
boolean    ``True`` / ``False``
number     ``float`` (always a float, never an ``int``)
string     ``str``
array      ``list`` (treated as immutable)
object     :class:`Obj`, an insertion-ordered ``dict`` (treated as immutable)
=========  ====================================================

Values are never mutated after construction, so they are shared freely.
"""

from __future__ import annotations

from typing import Any


class Obj(dict):
    """An insertion-ordered JSON object with a cached sorted-key tuple."""

    __slots__ = ("_sk",)

    def sorted_keys(self) -> tuple:
        """Keys in code-point order; computed at most once per object."""
        try:
            return self._sk
        except AttributeError:
            sk = self._sk = tuple(sorted(self))
            return sk


_TYPE_NAMES = {
    type(None): "null",
    bool: "boolean",
    float: "number",
    str: "string",
    list: "array",
    Obj: "object",
}


def type_name(v: Any) -> str:
    """The jq ``type`` of a value."""
    return _TYPE_NAMES[type(v)]


def is_truthy(v: Any) -> bool:
    return v is not None and v is not False


def sort_key(v: Any) -> tuple:
    """Map a value to a tuple whose native ordering is jq's total order.

    Two values are equal under jq iff their keys are equal.
    """
    t = type(v)
    if t is float:
        return (3, v)
    if t is str:
        return (4, v)
    if v is None:
        return (0,)
    if v is False:
        return (1,)
    if v is True:
        return (2,)
    if t is list:
        return (5, tuple([sort_key(x) for x in v]))
    if t is Obj:
        ks = v.sorted_keys()
        return (6, ks, tuple([sort_key(v[k]) for k in ks]))
    raise TypeError(f"not a jq value: {v!r}")


def compare(a: Any, b: Any) -> int:
    """Three-way comparison under jq's ordering: -1, 0 or 1."""
    ka, kb = sort_key(a), sort_key(b)
    return (ka > kb) - (ka < kb)


def equals(a: Any, b: Any) -> bool:
    """jq equality (object key order is irrelevant; 1 == 1.0)."""
    ta = type(a)
    if ta is type(b) and (ta is float or ta is str):
        return a == b
    return sort_key(a) == sort_key(b)


def from_native(obj: Any) -> Any:
    """Convert ordinary Python data (dict/list/int/float/str/bool/None) to jq values."""
    t = type(obj)
    if obj is None or t is bool or t is str:
        return obj
    if t is float:
        return obj
    if t is int:
        return float(obj)
    if isinstance(obj, dict):
        o = Obj()
        for k, v in obj.items():
            if not isinstance(k, str):
                raise TypeError("object keys must be strings")
            o[k] = from_native(v)
        return o
    if isinstance(obj, (list, tuple)):
        return [from_native(x) for x in obj]
    raise TypeError(f"cannot convert {t.__name__} to a jq value")


def to_native(v: Any) -> Any:
    """Convert a jq value to plain Python data (integral numbers become ``int``)."""
    t = type(v)
    if t is float:
        return int(v) if v.is_integer() else v
    if t is list:
        return [to_native(x) for x in v]
    if t is Obj:
        return {k: to_native(x) for k, x in v.items()}
    return v
