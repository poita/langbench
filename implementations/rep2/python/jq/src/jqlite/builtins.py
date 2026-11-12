"""Builtin functions.

``BUILTINS`` maps ``(name, arity)`` to a factory that receives the compiled
argument filters (:class:`~jqlite.runtime.Code`) and returns the compiled
builtin.
"""

from __future__ import annotations

import re
from typing import Any, Callable, Dict, Tuple

from .errors import JQError
from .jsonio import dumps
from .ops import add as _add_values
from .ops import iter_values
from .runtime import Code, from_gen, from_single
from .values import Obj, is_truthy, sort_key, type_name

BUILTINS: Dict[Tuple[str, int], Callable[..., Code]] = {}


def _describe(v: Any) -> str:
    text = dumps(v)
    if len(text) > 11:
        text = text[:10] + "..."
    return f"{type_name(v)} ({text})"


def _array_only(v: Any, what: str) -> list:
    if type(v) is not list:
        raise JQError(f"{_describe(v)} cannot be {what}")
    return v


# -- registration helpers -----------------------------------------------------

def plain(name: str):
    """Register ``fn(input) -> value`` as a zero-argument builtin."""

    def deco(fn):
        def factory():
            return from_single(lambda inp, env: fn(inp))

        BUILTINS[(name, 0)] = factory
        return fn

    return deco


def with_value_arg(name: str):
    """Register ``fn(input, arg) -> value``; runs once per output of the argument."""

    def deco(fn):
        def factory(arg: Code):
            a_s, a_g = arg.single, arg.gen
            if a_s is not None:
                return from_single(lambda inp, env: fn(inp, a_s(inp, env)))
            return from_gen(lambda inp, env: (fn(inp, k) for k in a_g(inp, env)))

        BUILTINS[(name, 1)] = factory
        return fn

    return deco


# -- core ---------------------------------------------------------------------

def _empty():
    return from_gen(lambda inp, env: ())


BUILTINS[("empty", 0)] = _empty


def _error0():
    def gen(inp, env):
        raise JQError(inp)

    return from_gen(gen)


def _error1(arg: Code):
    def gen(inp, env):
        for v in arg.gen(inp, env):
            raise JQError(v)
        return ()

    return from_gen(gen)


BUILTINS[("error", 0)] = _error0
BUILTINS[("error", 1)] = _error1


@plain("not")
def _not(v):
    return v is None or v is False


@plain("type")
def _type(v):
    return type_name(v)


@plain("length")
def _length(v):
    t = type(v)
    if t is list or t is str or t is Obj:
        return float(len(v))
    if v is None:
        return 0.0
    if t is float:
        return abs(v)
    raise JQError(f"{_describe(v)} has no length")


@plain("keys")
def _keys(v):
    t = type(v)
    if t is Obj:
        return list(v.sorted_keys())
    if t is list:
        return [float(i) for i in range(len(v))]
    raise JQError(f"{_describe(v)} has no keys")


@with_value_arg("has")
def _has(v, k):
    if v is None:
        return False
    tv, tk = type(v), type(k)
    if tv is Obj and tk is str:
        return k in v
    if tv is list and tk is float:
        return 0 <= int(k) < len(v)
    raise JQError(f"Cannot check whether {type_name(v)} has a {'string' if tk is str else type_name(k)} key")


@plain("add")
def _add(v):
    """Linear-time ``reduce .[] as $x (null; . + $x)``."""
    items = [x for x in iter_values(v) if x is not None]
    if not items:
        return None
    t = type(items[0])
    if all(type(x) is t for x in items):
        if t is float:
            acc = 0.0
            for x in items:
                acc += x
            return acc
        if t is str:
            return "".join(items)
        if t is list:
            out: list = []
            for x in items:
                out.extend(x)
            return out
        if t is Obj:
            out_o = Obj()
            for x in items:
                out_o.update(x)
            return out_o
    acc = items[0]
    for x in items[1:]:
        acc = _add_values(acc, x)  # raises the appropriate type error
    return acc


@plain("tostring")
def _tostring(v):
    return v if type(v) is str else dumps(v)


_NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")


@plain("tonumber")
def _tonumber(v):
    if type(v) is float:
        return v
    if type(v) is str and _NUMBER.fullmatch(v):
        return float(v)
    raise JQError(f"Cannot parse {_describe(v)} as a number")


@plain("reverse")
def _reverse(v):
    if v is None:
        return []
    if type(v) is list:
        return v[::-1]
    raise JQError(f"Cannot reverse {_describe(v)}")


# -- sorting and grouping -----------------------------------------------------

@plain("sort")
def _sort(v):
    _array_only(v, "sorted, as it is not an array")
    return sorted(v, key=sort_key)


@plain("unique")
def _unique(v):
    _array_only(v, "sorted, as it is not an array")
    keyed = sorted([(sort_key(x), x) for x in v], key=_first)
    out = []
    prev = None
    for k, x in keyed:
        if prev is None or k != prev:
            out.append(x)
            prev = k
    return out


def _first(pair):
    return pair[0]


@plain("min")
def _min(v):
    _array_only(v, "iterated over")
    best = None
    best_key = None
    for x in v:
        k = sort_key(x)
        if best_key is None or k < best_key:
            best, best_key = x, k
    return best


@plain("max")
def _max(v):
    _array_only(v, "iterated over")
    best = None
    best_key = None
    for x in v:
        k = sort_key(x)
        if best_key is None or k >= best_key:
            best, best_key = x, k
    return best


def _key_function(arg: Code):
    """Return ``f(x, env) -> sort key of [arg]`` evaluating the key once per element."""
    a_s, a_g = arg.single, arg.gen
    if a_s is not None:
        return lambda x, env: (5, (sort_key(a_s(x, env)),))
    return lambda x, env: sort_key(list(a_g(x, env)))


def _sort_by(arg: Code):
    keyf = _key_function(arg)

    def single(inp, env):
        _array_only(inp, "sorted, as it is not an array")
        keyed = [(keyf(x, env), x) for x in inp]
        keyed.sort(key=_first)
        return [x for _, x in keyed]

    return from_single(single)


def _group_by(arg: Code):
    keyf = _key_function(arg)

    def single(inp, env):
        _array_only(inp, "grouped, as it is not an array")
        keyed = [(keyf(x, env), x) for x in inp]
        keyed.sort(key=_first)
        groups: list = []
        prev = None
        for k, x in keyed:
            if groups and k == prev:
                groups[-1].append(x)
            else:
                groups.append([x])
                prev = k
        return groups

    return from_single(single)


BUILTINS[("sort_by", 1)] = _sort_by
BUILTINS[("group_by", 1)] = _group_by


# -- higher-order ---------------------------------------------------------------

def _select(arg: Code):
    a_s, a_g = arg.single, arg.gen
    if a_s is not None:
        return from_gen(lambda inp, env: (inp,) if is_truthy(a_s(inp, env)) else ())

    def gen(inp, env):
        for c in a_g(inp, env):
            if is_truthy(c):
                yield inp

    return from_gen(gen)


def _map(arg: Code):
    a_s, a_g = arg.single, arg.gen
    if a_s is not None:
        return from_single(lambda inp, env: [a_s(x, env) for x in iter_values(inp)])

    def single(inp, env):
        out = []
        for x in iter_values(inp):
            out.extend(a_g(x, env))
        return out

    return from_single(single)


BUILTINS[("select", 1)] = _select
BUILTINS[("map", 1)] = _map
