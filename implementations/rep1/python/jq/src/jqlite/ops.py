"""Primitive operations on jq values: arithmetic, comparison, indexing."""

from __future__ import annotations

import math
from typing import Any

from .errors import JQError
from .values import Obj, equal, sort_key, type_name


def _err(op: str, a: Any, b: Any) -> JQError:
    return JQError(f"{type_name(a)} and {type_name(b)} cannot be {op}")


# --------------------------------------------------------------------------
# Arithmetic

def add(a: Any, b: Any) -> Any:
    ta = type(a)
    if ta is float and type(b) is float:
        return a + b
    if a is None:
        return b
    if b is None:
        return a
    if ta is not type(b):
        raise _err("added", a, b)
    if ta is str or ta is list:
        return a + b
    if ta is Obj:
        out = Obj(a)
        out.update(b)
        return out
    raise _err("added", a, b)


def subtract(a: Any, b: Any) -> Any:
    ta = type(a)
    if ta is float and type(b) is float:
        return a - b
    if ta is list and type(b) is list:
        if not b:
            return a
        drop = {sort_key(x) for x in b}
        return [x for x in a if sort_key(x) not in drop]
    raise _err("subtracted", a, b)


def merge_deep(a: Obj, b: Obj) -> Obj:
    """Recursive object merge: ``b`` wins except where both sides are objects."""
    out = Obj(a)
    for k, bv in b.items():
        av = out.get(k)
        if type(av) is Obj and type(bv) is Obj:
            out[k] = merge_deep(av, bv)
        else:
            out[k] = bv
    return out


def multiply(a: Any, b: Any) -> Any:
    ta, tb = type(a), type(b)
    if ta is float and tb is float:
        return a * b
    if ta is str and tb is float:
        return _repeat(a, b)
    if ta is float and tb is str:
        return _repeat(b, a)
    if ta is Obj and tb is Obj:
        return merge_deep(a, b)
    raise _err("multiplied", a, b)


def _repeat(s: str, n: float) -> Any:
    if n < 0:
        return None
    return s * int(n)


def divide(a: Any, b: Any) -> Any:
    ta, tb = type(a), type(b)
    if ta is float and tb is float:
        if b == 0:
            raise _err("divided because the divisor is zero", a, b)
        return a / b
    if ta is str and tb is str:
        if not a:
            return []
        if not b:
            return list(a)
        return a.split(b)
    raise _err("divided", a, b)


def modulo(a: Any, b: Any) -> Any:
    if type(a) is float and type(b) is float:
        x, y = int(a), int(b)
        if y == 0:
            raise _err("divided because the divisor is zero", a, b)
        r = abs(x) % abs(y)
        return float(r if x >= 0 else -r)
    raise _err("divided", a, b)


def negate(a: Any) -> Any:
    if type(a) is float:
        return -a
    raise JQError(f"{type_name(a)} cannot be negated")


# --------------------------------------------------------------------------
# Comparison

def eq(a: Any, b: Any) -> bool:
    return equal(a, b)


def ne(a: Any, b: Any) -> bool:
    return not equal(a, b)


def _scalar_pair(a: Any, b: Any) -> bool:
    ta = type(a)
    return ta is type(b) and (ta is float or ta is str)


def lt(a: Any, b: Any) -> bool:
    if _scalar_pair(a, b):
        return a < b
    return sort_key(a) < sort_key(b)


def le(a: Any, b: Any) -> bool:
    if _scalar_pair(a, b):
        return a <= b
    return sort_key(a) <= sort_key(b)


def gt(a: Any, b: Any) -> bool:
    if _scalar_pair(a, b):
        return a > b
    return sort_key(a) > sort_key(b)


def ge(a: Any, b: Any) -> bool:
    if _scalar_pair(a, b):
        return a >= b
    return sort_key(a) >= sort_key(b)


BINARY_OPS = {
    "+": add, "-": subtract, "*": multiply, "/": divide, "%": modulo,
    "==": eq, "!=": ne, "<": lt, "<=": le, ">": gt, ">=": ge,
}


# --------------------------------------------------------------------------
# Paths

def index_value(t: Any, k: Any) -> Any:
    """``t[k]`` for a string or number key."""
    tk = type(k)
    if tk is str:
        if type(t) is Obj:
            return t.get(k)
        if t is None:
            return None
        raise JQError(f"cannot index {type_name(t)} with string")
    if tk is float:
        if type(t) is list:
            i = int(k)
            n = len(t)
            if i < 0:
                i += n
            if 0 <= i < n:
                return t[i]
            return None
        if t is None:
            return None
        raise JQError(f"cannot index {type_name(t)} with number")
    raise JQError(f"cannot index {type_name(t)} with {type_name(k)}")


def slice_value(t: Any, a: Any, b: Any) -> Any:
    """``t[a:b]``; ``None`` bounds mean "omitted"."""
    if t is None:
        return None
    tt = type(t)
    if tt is not list and tt is not str:
        raise JQError(f"cannot slice {type_name(t)}")
    if (a is not None and type(a) is not float) or (b is not None and type(b) is not float):
        raise JQError("start and end indices of an array slice must be numbers")
    n = len(t)
    lo = 0 if a is None else a
    hi = n if b is None else b
    if lo < 0:
        lo += n
    if hi < 0:
        hi += n
    lo = min(max(math.floor(lo), 0), n)
    hi = min(max(math.ceil(hi), 0), n)
    if hi < lo:
        hi = lo
    return t[lo:hi]


def iterate(t: Any):
    """The values ``.[]`` produces for ``t`` (an iterable), or raise."""
    tt = type(t)
    if tt is list:
        return t
    if tt is Obj:
        return t.values()
    raise JQError(f"cannot iterate over {type_name(t)}")
