"""Compile a syntax tree into Python closures and evaluate them.

Every node compiles to a pair ``(gen, direct)``:

* ``gen(inp, env)`` returns an iterable of the node's outputs, in jq order.
  It is only iterated once and lazily consumed, so an error is raised at the
  point in the stream where it occurs.
* ``direct(inp, env)`` is provided when the node always yields exactly one
  output (or raises); it returns that value without any generator overhead.
  It is ``None`` for nodes that can yield zero or several outputs.

``env`` is the variable environment: a persistent linked list of
``(name, value, parent)`` tuples (``None`` when empty), so binding is O(1)
and shares everything.
"""

from __future__ import annotations

from typing import Any, Callable, Iterable

from . import builtins
from .errors import JQError
from .ops import BINARY_OPS, index_value, iterate, negate, slice_value
from .parser import Node
from .values import Obj, type_name

Gen = Callable[[Any, Any], Iterable]
Direct = Callable[[Any, Any], Any]
Compiled = tuple[Gen, "Direct | None"]

_NOTHING = object()


def from_direct(d: Direct) -> Gen:
    return lambda i, e: (d(i, e),)


def compile_node(node: Node) -> Compiled:
    """Compile a syntax tree node."""
    return _COMPILERS[node[0]](node)


def _c_id(node: Node) -> Compiled:
    return (lambda i, e: (i,)), (lambda i, e: i)


def _c_lit(node: Node) -> Compiled:
    v = node[1]
    return (lambda i, e: (v,)), (lambda i, e: v)


def _c_var(node: Node) -> Compiled:
    name = node[1]

    def direct(i, e):
        while e is not None:
            if e[0] == name:
                return e[1]
            e = e[2]
        raise JQError(f"${name} is not defined")

    return from_direct(direct), direct


def _c_group(node: Node) -> Compiled:
    return compile_node(node[1])


def _c_index(node: Node) -> Compiled:
    _, target, key, opt = node
    tg, td = compile_node(target)
    kg, kd = compile_node(key)
    if td is not None and kd is not None and not opt:
        if key[0] == "lit" and type(key[1]) is str:
            name = key[1]

            def direct(i, e):
                t = td(i, e)
                if type(t) is Obj:
                    return t.get(name)
                if t is None:
                    return None
                raise JQError(f"cannot index {type_name(t)} with string")
        else:
            def direct(i, e):
                k = kd(i, e)
                return index_value(td(i, e), k)

        return from_direct(direct), direct

    if opt:
        def gen(i, e):
            for k in kg(i, e):
                for t in tg(i, e):
                    try:
                        r = index_value(t, k)
                    except JQError:
                        continue
                    yield r
    else:
        def gen(i, e):
            for k in kg(i, e):
                for t in tg(i, e):
                    yield index_value(t, k)
    return gen, None


def _c_iter(node: Node) -> Compiled:
    _, target, opt = node
    tg, td = compile_node(target)

    if opt:
        def gen(i, e):
            for t in tg(i, e):
                tt = type(t)
                if tt is list:
                    yield from t
                elif tt is Obj:
                    yield from t.values()
    elif td is not None:
        def gen(i, e):
            return iterate(td(i, e))
    else:
        def gen(i, e):
            for t in tg(i, e):
                yield from iterate(t)
    return gen, None


def _c_slice(node: Node) -> Compiled:
    _, target, lo, hi, opt = node
    tg, _ = compile_node(target)
    lg, _ = compile_node(lo)
    hg, _ = compile_node(hi)

    def gen(i, e):
        for a in lg(i, e):
            for b in hg(i, e):
                for t in tg(i, e):
                    if opt:
                        try:
                            r = slice_value(t, a, b)
                        except JQError:
                            continue
                        yield r
                    else:
                        yield slice_value(t, a, b)

    return gen, None


def _c_try(node: Node) -> Compiled:
    g, _ = compile_node(node[1])

    def gen(i, e):
        try:
            yield from g(i, e)
        except JQError:
            return

    return gen, None


def _c_neg(node: Node) -> Compiled:
    g, d = compile_node(node[1])
    if d is not None:
        direct = lambda i, e: negate(d(i, e))
        return from_direct(direct), direct

    def gen(i, e):
        for v in g(i, e):
            yield negate(v)

    return gen, None


def _c_binop(node: Node) -> Compiled:
    _, op, left, right = node
    fn = BINARY_OPS[op]
    lg, ld = compile_node(left)
    rg, rd = compile_node(right)
    if ld is not None and rd is not None:
        def direct(i, e):
            b = rd(i, e)
            return fn(ld(i, e), b)

        return from_direct(direct), direct

    def gen(i, e):
        for b in rg(i, e):
            for a in lg(i, e):
                yield fn(a, b)

    return gen, None


def _c_and(node: Node) -> Compiled:
    lg, ld = compile_node(node[1])
    rg, rd = compile_node(node[2])
    if ld is not None and rd is not None:
        def direct(i, e):
            a = ld(i, e)
            if a is None or a is False:
                return False
            b = rd(i, e)
            return b is not None and b is not False

        return from_direct(direct), direct

    def gen(i, e):
        for a in lg(i, e):
            if a is None or a is False:
                yield False
            else:
                for b in rg(i, e):
                    yield b is not None and b is not False

    return gen, None


def _c_or(node: Node) -> Compiled:
    lg, ld = compile_node(node[1])
    rg, rd = compile_node(node[2])
    if ld is not None and rd is not None:
        def direct(i, e):
            a = ld(i, e)
            if a is not None and a is not False:
                return True
            b = rd(i, e)
            return b is not None and b is not False

        return from_direct(direct), direct

    def gen(i, e):
        for a in lg(i, e):
            if a is not None and a is not False:
                yield True
            else:
                for b in rg(i, e):
                    yield b is not None and b is not False

    return gen, None


def _c_pipe(node: Node) -> Compiled:
    lg, ld = compile_node(node[1])
    rg, rd = compile_node(node[2])
    if ld is not None and rd is not None:
        direct = lambda i, e: rd(ld(i, e), e)
        return from_direct(direct), direct
    if ld is not None:
        return (lambda i, e: rg(ld(i, e), e)), None
    if rd is not None:
        def gen(i, e):
            for v in lg(i, e):
                yield rd(v, e)
    else:
        def gen(i, e):
            for v in lg(i, e):
                yield from rg(v, e)
    return gen, None


def _c_comma(node: Node) -> Compiled:
    lg, _ = compile_node(node[1])
    rg, _ = compile_node(node[2])

    def gen(i, e):
        yield from lg(i, e)
        yield from rg(i, e)

    return gen, None


def _c_as(node: Node) -> Compiled:
    _, src, name, body = node
    sg, sd = compile_node(src)
    bg, bd = compile_node(body)
    if sd is not None and bd is not None:
        direct = lambda i, e: bd(i, (name, sd(i, e), e))
        return from_direct(direct), direct
    if sd is not None:
        return (lambda i, e: bg(i, (name, sd(i, e), e))), None

    def gen(i, e):
        for v in sg(i, e):
            yield from bg(i, (name, v, e))

    return gen, None


def _c_reduce(node: Node) -> Compiled:
    _, src, name, init, update = node
    sg, _ = compile_node(src)
    ig, _ = compile_node(init)
    ug, ud = compile_node(update)

    def gen(i, e):
        for acc in ig(i, e):
            for v in sg(i, e):
                if ud is not None:
                    acc = ud(acc, (name, v, e))
                else:
                    last = None  # no output from UPDATE means null
                    for last in ug(acc, (name, v, e)):
                        pass
                    acc = last
            yield acc

    return gen, None


def _c_if(node: Node) -> Compiled:
    _, cond, then, els = node
    cg, cd = compile_node(cond)
    tg, td = compile_node(then)
    eg, ed = compile_node(els) if els is not None else compile_node(("id",))
    if cd is not None and td is not None and ed is not None:
        def direct(i, e):
            c = cd(i, e)
            if c is not None and c is not False:
                return td(i, e)
            return ed(i, e)

        return from_direct(direct), direct
    if cd is not None:
        def gen(i, e):
            c = cd(i, e)
            return tg(i, e) if (c is not None and c is not False) else eg(i, e)
    else:
        def gen(i, e):
            for c in cg(i, e):
                if c is not None and c is not False:
                    yield from tg(i, e)
                else:
                    yield from eg(i, e)
    return gen, None


def _c_array(node: Node) -> Compiled:
    body = node[1]
    if body is None:
        direct = lambda i, e: []
    else:
        g, d = compile_node(body)
        if d is not None:
            direct = lambda i, e: [d(i, e)]
        else:
            direct = lambda i, e: list(g(i, e))
    return from_direct(direct), direct


def _c_object(node: Node) -> Compiled:
    entries = [(compile_node(k), compile_node(v)) for k, v in node[1]]
    n = len(entries)

    def check_key(k):
        if type(k) is not str:
            raise JQError(f"object key must be a string, not {type_name(k)}")
        return k

    if all(kc[1] is not None and vc[1] is not None for kc, vc in entries):
        pairs = [(kc[1], vc[1]) for kc, vc in entries]

        def direct(i, e):
            return Obj([(check_key(kd(i, e)), vd(i, e)) for kd, vd in pairs])

        return from_direct(direct), direct

    gens = [(kc[0], vc[0]) for kc, vc in entries]

    def gen(i, e):
        acc: list = []

        def rec(idx):
            if idx == n:
                yield Obj(acc)
                return
            kg, vg = gens[idx]
            for k in kg(i, e):
                check_key(k)
                for v in vg(i, e):
                    acc.append((k, v))
                    yield from rec(idx + 1)
                    acc.pop()

        return rec(0)

    return gen, None


def _c_call(node: Node) -> Compiled:
    _, name, args = node
    compiled = [compile_node(a) for a in args]
    return builtins.compile_call(name, compiled)


_COMPILERS = {
    "id": _c_id, "lit": _c_lit, "var": _c_var, "group": _c_group,
    "index": _c_index, "iter": _c_iter, "slice": _c_slice, "try": _c_try,
    "neg": _c_neg, "binop": _c_binop, "and": _c_and, "or": _c_or,
    "pipe": _c_pipe, "comma": _c_comma, "as": _c_as, "reduce": _c_reduce,
    "if": _c_if, "array": _c_array, "object": _c_object, "call": _c_call,
}
