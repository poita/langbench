"""Run-time value helpers shared by the VM and the standard library.

Representation: Int -> ``int``; Float -> ``float``; Bool -> ``bool``; Str -> ``str``;
Char -> :class:`Char` (a one-scalar ``str`` subclass, so a trait can tell it from a
one-character ``Str``); Unit -> ``None``; list -> ``list``; map -> ``dict`` (Python
dicts keep insertion order, including delete-and-reinsert); tuple -> ``tuple``;
struct and enum values -> tuples whose element 0 is the declaration's/variant's
unique id; closures -> :class:`Closure`.
"""

from __future__ import annotations


class Char(str):
    __slots__ = ()


class Closure:
    __slots__ = ("code", "up")

    def __init__(self, code, up):
        self.code = code
        self.up = up


def veq(a, b) -> bool:
    """Structural equality that never takes Python's identity shortcut (NaN != NaN)."""
    t = type(a)
    if t is float:
        return a == b
    if t is tuple:
        if len(a) != len(b):
            return False
        for x, y in zip(a, b):
            if not veq(x, y):
                return False
        return True
    if t is list:
        if len(a) != len(b):
            return False
        for x, y in zip(a, b):
            if not veq(x, y):
                return False
        return True
    if t is dict:
        if len(a) != len(b):
            return False
        for k, v in a.items():
            if k not in b or not veq(v, b[k]):
                return False
        return True
    return a == b
