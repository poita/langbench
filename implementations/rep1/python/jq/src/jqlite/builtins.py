"""The built-in functions of the supported jq subset.

``compile_call(name, args)`` receives the already-compiled argument filters
(each a ``(gen, direct)`` pair, see :mod:`jqlite.interp`) and returns the
compiled call.
"""

from __future__ import annotations

import re
from typing import Any, Callable

from .errors import JQError, JQSyntaxError
from .jsonio import dumps
from .ops import add as add_values
from .ops import iterate
from .values import Obj, equal, is_true, sort_key, type_name

_NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?")


# --------------------------------------------------------------------------
# Plain functions of the input value

def _length(v: Any) -> float:
    t = type(v)
    if v is None:
        return 0.0
    if t is float:
        return abs(v)
    if t is str or t is list or t is Obj:
        return float(len(v))
    raise JQError(f"{type_name(v)} has no length")


def _keys(v: Any) -> list:
    t = type(v)
    if t is Obj:
        return list(v.sorted_keys())
    if t is list:
        return [float(i) for i in range(len(v))]
    raise JQError(f"{type_name(v)} has no keys")


def _type(v: Any) -> str:
    return type_name(v)


def _not(v: Any) -> bool:
    return v is None or v is False


def _add(v: Any) -> Any:
    """Sum of the elements/values with ``+``, in linear total time.

    Same result as ``reduce .[] as $x (null; . + $x)``, but runs of strings,
    arrays and objects are accumulated in one builder rather than copied per
    step.
    """
    items = iterate(v)
    acc: Any = None
    kind = None          # None (plain value), "str", "list", "obj"
    parts: list = []     # builder for "str" / "list"
    for x in items:
        if x is None:
            continue
        tx = type(x)
        if kind == "str" and tx is str:
            parts.append(x)
            continue
        if kind == "list" and tx is list:
            parts.extend(x)
            continue
        if kind == "obj" and tx is Obj:
            acc.update(x)
            continue
        # Leave builder mode and fall back to the generic operation.
        if kind == "str":
            acc = "".join(parts)
        elif kind == "list":
            acc = parts
        kind = None
        if acc is None:
            acc = x
            tx = type(acc)
        else:
            acc = add_values(acc, x)
            tx = type(acc)
        if tx is str:
            kind, parts = "str", [acc]
        elif tx is list:
            kind, parts = "list", list(acc)
        elif tx is Obj:
            kind = "obj"
            acc = Obj(acc)
    if kind == "str":
        return "".join(parts)
    if kind == "list":
        return parts
    return acc


def _sort(v: Any) -> list:
    if type(v) is not list:
        raise JQError(f"{type_name(v)} cannot be sorted, as it is not an array")
    return sorted(v, key=sort_key)


def _unique(v: Any) -> list:
    if type(v) is not list:
        raise JQError(f"{type_name(v)} cannot be sorted, as it is not an array")
    out: list = []
    prev = None
    for x in sorted(v, key=sort_key):
        k = sort_key(x)
        if not out or k != prev:
            out.append(x)
            prev = k
    return out


def _reverse(v: Any) -> list:
    if type(v) is list:
        return v[::-1]
    if v is None:
        return []
    raise JQError(f"cannot reverse {type_name(v)}")


def _min(v: Any) -> Any:
    if type(v) is not list:
        raise JQError(f"{type_name(v)} cannot be iterated over for min")
    best = None
    best_key = None
    for x in v:
        k = sort_key(x)
        if best_key is None or k < best_key:
            best, best_key = x, k
    return best


def _max(v: Any) -> Any:
    if type(v) is not list:
        raise JQError(f"{type_name(v)} cannot be iterated over for max")
    best = None
    best_key = None
    for x in v:
        k = sort_key(x)
        if best_key is None or k >= best_key:
            best, best_key = x, k
    return best


def _tostring(v: Any) -> str:
    return v if type(v) is str else dumps(v)


def _tonumber(v: Any) -> float:
    t = type(v)
    if t is float:
        return v
    if t is str and _NUMBER.fullmatch(v):
        return float(v)
    raise JQError(f"cannot parse {dumps(v)} as a number")


def _has(v: Any, k: Any) -> bool:
    t = type(v)
    if t is Obj and type(k) is str:
        return k in v
    if t is list and type(k) is float:
        return 0 <= int(k) < len(v)
    if v is None:
        return False
    raise JQError(f"cannot check whether {type_name(v)} has a {type_name(k)} key")


_PLAIN: dict[str, Callable[[Any], Any]] = {
    "length": _length, "keys": _keys, "type": _type, "not": _not, "add": _add,
    "sort": _sort, "unique": _unique, "reverse": _reverse, "min": _min,
    "max": _max, "tostring": _tostring, "tonumber": _tonumber,
}


# --------------------------------------------------------------------------
# Sorting by a key filter

def _keyed(v: Any, fg, e) -> tuple[list, list]:
    """Return ``(elements, sort keys)`` where the key is ``sort_key([f])``."""
    if type(v) is not list:
        raise JQError(f"{type_name(v)} cannot be sorted, as it is not an array")
    return v, [sort_key(list(fg(x, e))) for x in v]


def _sort_by(fg):
    def direct(i, e):
        v, keys = _keyed(i, fg, e)
        order = sorted(range(len(v)), key=keys.__getitem__)
        return [v[j] for j in order]

    return direct


def _group_by(fg):
    def direct(i, e):
        v, keys = _keyed(i, fg, e)
        order = sorted(range(len(v)), key=keys.__getitem__)
        groups: list = []
        prev = None
        for j in order:
            if groups and keys[j] == prev:
                groups[-1].append(v[j])
            else:
                groups.append([v[j]])
                prev = keys[j]
        return groups

    return direct


# --------------------------------------------------------------------------

def compile_call(name: str, args: list) -> tuple:
    """Compile a call of builtin ``name`` with compiled argument filters."""
    n = len(args)

    def from_direct(d):
        return (lambda i, e: (d(i, e),)), d

    if n == 0:
        if name in _PLAIN:
            fn = _PLAIN[name]
            return from_direct(lambda i, e: fn(i))
        if name == "empty":
            return (lambda i, e: ()), None
        if name == "error":
            def raise_input(i, e):
                raise JQError("error", i)

            return raise_input, None
    elif n == 1:
        ag, ad = args[0]
        if name == "error":
            def gen(i, e):
                for v in ag(i, e):
                    raise JQError("error", v)
                return ()

            return gen, None
        if name == "select":
            if ad is not None:
                def gen(i, e):
                    c = ad(i, e)
                    return (i,) if (c is not None and c is not False) else ()
            else:
                def gen(i, e):
                    for c in ag(i, e):
                        if c is not None and c is not False:
                            yield i
            return gen, None
        if name == "map":
            if ad is not None:
                return from_direct(lambda i, e: [ad(x, e) for x in iterate(i)])

            def map_direct(i, e):
                out: list = []
                for x in iterate(i):
                    out.extend(ag(x, e))
                return out

            return from_direct(map_direct)
        if name == "sort_by":
            return from_direct(_sort_by(ag))
        if name == "group_by":
            return from_direct(_group_by(ag))
        if name == "has":
            if ad is not None:
                return from_direct(lambda i, e: _has(i, ad(i, e)))

            def has_gen(i, e):
                for k in ag(i, e):
                    yield _has(i, k)

            return has_gen, None
    raise JQSyntaxError(f"unknown function {name}/{n}")
