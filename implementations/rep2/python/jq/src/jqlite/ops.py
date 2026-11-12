"""Primitive operations: arithmetic, comparison, indexing and slicing."""

from __future__ import annotations

import math
from typing import Any, Callable, Dict

from .errors import JQError
from .jsonio import dumps
from .values import Obj, equals, sort_key, type_name


def _describe(v: Any) -> str:
    text = dumps(v)
    if len(text) > 11:
        text = text[:10] + "..."
    return f"{type_name(v)} ({text})"


def _binop_error(a: Any, b: Any, what: str) -> JQError:
    return JQError(f"{_describe(a)} and {_describe(b)} cannot be {what}")


# --------------------------------------------------------------------------
# Arithmetic
# --------------------------------------------------------------------------

def add(a: Any, b: Any) -> Any:
    ta, tb = type(a), type(b)
    if ta is float and tb is float:
        return a + b
    if a is None:
        return b
    if b is None:
        return a
    if ta is tb:
        if ta is str or ta is list:
            return a + b
        if ta is Obj:
            r = Obj(a)
            r.update(b)
            return r
    raise _binop_error(a, b, "added")


def sub(a: Any, b: Any) -> Any:
    ta, tb = type(a), type(b)
    if ta is float and tb is float:
        return a - b
    if ta is list and tb is list:
        if not b:
            return a
        drop = {sort_key(x) for x in b}
        return [x for x in a if sort_key(x) not in drop]
    raise _binop_error(a, b, "subtracted")


def deep_merge(a: Obj, b: Obj) -> Obj:
    r = Obj(a)
    for k, bv in b.items():
        av = r.get(k)
        if type(av) is Obj and type(bv) is Obj:
            r[k] = deep_merge(av, bv)
        else:
            r[k] = bv
    return r


def mul(a: Any, b: Any) -> Any:
    ta, tb = type(a), type(b)
    if ta is float and tb is float:
        return a * b
    if ta is str and tb is float:
        return _repeat(a, b)
    if ta is float and tb is str:
        return _repeat(b, a)
    if ta is Obj and tb is Obj:
        return deep_merge(a, b)
    raise _binop_error(a, b, "multiplied")


def _repeat(s: str, n: float) -> Any:
    if n < 0:
        return None
    return s * int(n)


def div(a: Any, b: Any) -> Any:
    ta, tb = type(a), type(b)
    if ta is float and tb is float:
        if b == 0:
            raise JQError(f"{_describe(a)} and {_describe(b)} cannot be divided because the divisor is zero")
        return a / b
    if ta is str and tb is str:
        if not a:
            return []
        if not b:
            return list(a)
        return a.split(b)
    raise _binop_error(a, b, "divided")


def mod(a: Any, b: Any) -> Any:
    if type(a) is float and type(b) is float:
        try:
            x, y = int(a), int(b)
        except (OverflowError, ValueError):
            raise JQError(f"{_describe(a)} and {_describe(b)} cannot be divided") from None
        if y == 0:
            raise JQError(f"{_describe(a)} and {_describe(b)} cannot be divided because the divisor is zero")
        r = abs(x) % abs(y)
        return float(-r if x < 0 else r)
    raise _binop_error(a, b, "divided")


# --------------------------------------------------------------------------
# Comparison
# --------------------------------------------------------------------------

def eq(a: Any, b: Any) -> bool:
    return equals(a, b)


def ne(a: Any, b: Any) -> bool:
    return not equals(a, b)


def _fast(a: Any, b: Any) -> bool:
    ta = type(a)
    return ta is type(b) and (ta is float or ta is str)


def lt(a: Any, b: Any) -> bool:
    if _fast(a, b):
        return a < b
    return sort_key(a) < sort_key(b)


def le(a: Any, b: Any) -> bool:
    if _fast(a, b):
        return a <= b
    return sort_key(a) <= sort_key(b)


def gt(a: Any, b: Any) -> bool:
    if _fast(a, b):
        return a > b
    return sort_key(a) > sort_key(b)


def ge(a: Any, b: Any) -> bool:
    if _fast(a, b):
        return a >= b
    return sort_key(a) >= sort_key(b)


BINARY_OPS: Dict[str, Callable[[Any, Any], Any]] = {
    "+": add,
    "-": sub,
    "*": mul,
    "/": div,
    "%": mod,
    "==": eq,
    "!=": ne,
    "<": lt,
    "<=": le,
    ">": gt,
    ">=": ge,
}


def negate(v: Any) -> Any:
    if type(v) is float:
        return -v
    raise JQError(f"{_describe(v)} cannot be negated")


# --------------------------------------------------------------------------
# Indexing
# --------------------------------------------------------------------------

def index_value(t: Any, k: Any) -> Any:
    """``t[k]`` for a string or numeric key."""
    tt, tk = type(t), type(k)
    if tt is Obj:
        if tk is str:
            return t.get(k)
    elif tt is list:
        if tk is float:
            n = len(t)
            i = int(k)
            if i < 0:
                i += n
            return t[i] if 0 <= i < n else None
    elif t is None:
        if tk is str or tk is float:
            return None
    if tk is str:
        raise JQError(f'Cannot index {type_name(t)} with "{k}"')
    raise JQError(f"Cannot index {type_name(t)} with {type_name(k)}")


def iter_values(t: Any) -> Any:
    """The values produced by ``t[]``."""
    tt = type(t)
    if tt is list:
        return t
    if tt is Obj:
        return t.values()
    raise JQError(f"Cannot iterate over {type_name(t)}")


def slice_value(t: Any, lo: Any, hi: Any) -> Any:
    """``t[lo:hi]``; ``lo``/``hi`` may be ``None`` for an omitted bound."""
    if t is None:
        return None
    tt = type(t)
    if tt is not list and tt is not str:
        raise JQError(f"Cannot index {type_name(t)} with object")
    if (lo is not None and type(lo) is not float) or (hi is not None and type(hi) is not float):
        raise JQError("Start and end indices of an array slice must be numbers")
    n = len(t)
    a = 0 if lo is None else math.floor(lo)
    b = n if hi is None else math.ceil(hi)
    if a < 0:
        a += n
    if b < 0:
        b += n
    a = min(max(a, 0), n)
    b = min(max(b, 0), n)
    if b < a:
        b = a
    return t[a:b]
