"""Compile a syntax tree into nested Python closures (see :mod:`jqlite.runtime`)."""

from __future__ import annotations

from typing import Tuple

from . import ast
from .errors import JQError, JQSyntaxError
from .ops import BINARY_OPS, index_value, iter_values, negate, slice_value
from .runtime import Code, from_gen, from_single
from .values import Obj, is_truthy, type_name


def compile_node(node: ast.Node, scope: Tuple[str, ...] = ()) -> Code:
    """Compile ``node``; ``scope`` lists the variable names visible at this point."""
    method = _DISPATCH.get(type(node))
    if method is None:  # pragma: no cover - parser never produces others
        raise JQSyntaxError(f"cannot compile {type(node).__name__}")
    return method(node, scope)


# -- leaves -----------------------------------------------------------------

def _identity(node, scope):
    return from_single(lambda inp, env: inp)


def _literal(node, scope):
    v = node.value
    return from_single(lambda inp, env: v)


def _var(node, scope):
    name = node.name
    if name not in scope:
        raise JQSyntaxError(f"${name} is not defined")

    def single(inp, env):
        while env is not None:
            if env[0] == name:
                return env[1]
            env = env[2]
        raise JQError(f"${name} is not defined")  # pragma: no cover

    return from_single(single)


# -- paths ------------------------------------------------------------------

def _index(node, scope):
    term = compile_node(node.term, scope)
    key = compile_node(node.key, scope)
    opt = node.opt
    ts, ks = term.single, key.single
    if not opt and ts is not None and ks is not None:
        if type(node.key) is ast.Literal:
            k = node.key.value

            def single(inp, env):
                t = ts(inp, env)
                if type(t) is Obj and type(k) is str:
                    return t.get(k)
                return index_value(t, k)

            return from_single(single)

        return from_single(lambda inp, env: index_value(ts(inp, env), ks(inp, env)))

    tg, kg = term.gen, key.gen

    def gen(inp, env):
        for k in kg(inp, env):
            for t in tg(inp, env):
                if opt:
                    try:
                        v = index_value(t, k)
                    except JQError:
                        continue
                    yield v
                else:
                    yield index_value(t, k)

    return from_gen(gen)


def _slice(node, scope):
    term = compile_node(node.term, scope)
    lo = compile_node(node.lo, scope) if node.lo is not None else None
    hi = compile_node(node.hi, scope) if node.hi is not None else None
    opt = node.opt
    none_gen = lambda inp, env: (None,)  # noqa: E731
    lg = lo.gen if lo is not None else none_gen
    hg = hi.gen if hi is not None else none_gen
    tg = term.gen

    def gen(inp, env):
        for a in lg(inp, env):
            for b in hg(inp, env):
                for t in tg(inp, env):
                    if opt:
                        try:
                            v = slice_value(t, a, b)
                        except JQError:
                            continue
                        yield v
                    else:
                        yield slice_value(t, a, b)

    return from_gen(gen)


def _iterate(node, scope):
    term = compile_node(node.term, scope)
    opt = node.opt
    ts, tg = term.single, term.gen
    if not opt:
        if ts is not None:
            return from_gen(lambda inp, env: iter_values(ts(inp, env)))

        def gen(inp, env):
            for t in tg(inp, env):
                yield from iter_values(t)

        return from_gen(gen)

    def gen_opt(inp, env):
        for t in tg(inp, env):
            try:
                items = iter_values(t)
            except JQError:
                continue
            yield from items

    return from_gen(gen_opt)


def _try(node, scope):
    body = compile_node(node.body, scope).gen

    def gen(inp, env):
        try:
            yield from body(inp, env)
        except JQError:
            return

    return from_gen(gen)


# -- combinators --------------------------------------------------------------

def _pipe(node, scope):
    left = compile_node(node.left, scope)
    right = compile_node(node.right, scope)
    ls, lg, rs, rg = left.single, left.gen, right.single, right.gen
    if ls is not None and rs is not None:
        return from_single(lambda inp, env: rs(ls(inp, env), env))
    if ls is not None:
        return from_gen(lambda inp, env: rg(ls(inp, env), env))
    if rs is not None:
        return from_gen(lambda inp, env: (rs(v, env) for v in lg(inp, env)))

    def gen(inp, env):
        for v in lg(inp, env):
            yield from rg(v, env)

    return from_gen(gen)


def _comma(node, scope):
    parts = []
    # Iterative left-spine flatten keeps long `a, b, c, ...` chains shallow.
    stack = [node]
    while stack:
        n = stack.pop()
        if type(n) is ast.Comma:
            stack.append(n.right)
            stack.append(n.left)
        else:
            parts.append(n)
    gens = tuple(compile_node(p, scope).gen for p in parts)

    def gen(inp, env):
        for g in gens:
            yield from g(inp, env)

    return from_gen(gen)


def _binop(node, scope):
    fn = BINARY_OPS[node.op]
    left = compile_node(node.left, scope)
    right = compile_node(node.right, scope)
    ls, lg, rs, rg = left.single, left.gen, right.single, right.gen
    if ls is not None and rs is not None:

        def single(inp, env):
            b = rs(inp, env)
            return fn(ls(inp, env), b)

        return from_single(single)
    if rs is not None:

        def gen_r(inp, env):
            b = rs(inp, env)
            return (fn(a, b) for a in lg(inp, env))

        return from_gen(gen_r)

    def gen(inp, env):
        for b in rg(inp, env):
            for a in lg(inp, env):
                yield fn(a, b)

    return from_gen(gen)


def _and(node, scope):
    left = compile_node(node.left, scope)
    right = compile_node(node.right, scope)
    ls, lg, rs, rg = left.single, left.gen, right.single, right.gen
    if ls is not None and rs is not None:

        def single(inp, env):
            if not is_truthy(ls(inp, env)):
                return False
            return is_truthy(rs(inp, env))

        return from_single(single)

    def gen(inp, env):
        for a in lg(inp, env):
            if not is_truthy(a):
                yield False
            else:
                for b in rg(inp, env):
                    yield is_truthy(b)

    return from_gen(gen)


def _or(node, scope):
    left = compile_node(node.left, scope)
    right = compile_node(node.right, scope)
    ls, lg, rs, rg = left.single, left.gen, right.single, right.gen
    if ls is not None and rs is not None:

        def single(inp, env):
            if is_truthy(ls(inp, env)):
                return True
            return is_truthy(rs(inp, env))

        return from_single(single)

    def gen(inp, env):
        for a in lg(inp, env):
            if is_truthy(a):
                yield True
            else:
                for b in rg(inp, env):
                    yield is_truthy(b)

    return from_gen(gen)


def _neg(node, scope):
    operand = compile_node(node.operand, scope)
    os_, og = operand.single, operand.gen
    if os_ is not None:
        return from_single(lambda inp, env: negate(os_(inp, env)))
    return from_gen(lambda inp, env: (negate(v) for v in og(inp, env)))


def _array(node, scope):
    if node.body is None:
        return from_single(lambda inp, env: [])
    body = compile_node(node.body, scope)
    bs, bg = body.single, body.gen
    if bs is not None:
        return from_single(lambda inp, env: [bs(inp, env)])
    return from_single(lambda inp, env: list(bg(inp, env)))


def _object(node, scope):
    entries = []
    for k, v in node.entries:
        entries.append((compile_node(k, scope), compile_node(v, scope)))
    n = len(entries)

    def check_key(k):
        if type(k) is not str:
            raise JQError(f"Object keys must be strings, not {type_name(k)}")
        return k

    if all(k.single is not None and v.single is not None for k, v in entries):
        pairs = tuple((k.single, v.single) for k, v in entries)

        def single(inp, env):
            o = Obj()
            for ks, vs in pairs:
                o[check_key(ks(inp, env))] = vs(inp, env)
            return o

        return from_single(single)

    gens = tuple((k.gen, v.gen) for k, v in entries)

    def rec(i, inp, env, pairs):
        if i == n:
            o = Obj()
            for k, v in pairs:
                o[k] = v
            yield o
            return
        kg, vg = gens[i]
        for k in kg(inp, env):
            check_key(k)
            for v in vg(inp, env):
                yield from rec(i + 1, inp, env, pairs + ((k, v),))

    return from_gen(lambda inp, env: rec(0, inp, env, ()))


def _if(node, scope):
    cond = compile_node(node.cond, scope)
    then = compile_node(node.then, scope)
    orelse = compile_node(node.orelse, scope) if node.orelse is not None else from_single(lambda inp, env: inp)
    cs, cg = cond.single, cond.gen
    if cs is not None:
        if then.single is not None and orelse.single is not None:
            ts, es = then.single, orelse.single
            return from_single(lambda inp, env: ts(inp, env) if is_truthy(cs(inp, env)) else es(inp, env))
        tg, eg = then.gen, orelse.gen
        return from_gen(lambda inp, env: tg(inp, env) if is_truthy(cs(inp, env)) else eg(inp, env))
    tg, eg = then.gen, orelse.gen

    def gen(inp, env):
        for c in cg(inp, env):
            if is_truthy(c):
                yield from tg(inp, env)
            else:
                yield from eg(inp, env)

    return from_gen(gen)


def _as(node, scope):
    source = compile_node(node.source, scope)
    body = compile_node(node.body, scope + (node.name,))
    name = node.name
    ss, sg, bs, bg = source.single, source.gen, body.single, body.gen
    if ss is not None:
        if bs is not None:
            return from_single(lambda inp, env: bs(inp, (name, ss(inp, env), env)))
        return from_gen(lambda inp, env: bg(inp, (name, ss(inp, env), env)))
    if bs is not None:
        return from_gen(lambda inp, env: (bs(inp, (name, v, env)) for v in sg(inp, env)))

    def gen(inp, env):
        for v in sg(inp, env):
            yield from bg(inp, (name, v, env))

    return from_gen(gen)


def _reduce(node, scope):
    source = compile_node(node.source, scope)
    init = compile_node(node.init, scope)
    update = compile_node(node.update, scope + (node.name,))
    name = node.name
    sg = source.gen
    us, ug = update.single, update.gen

    def run(acc, inp, env):
        if us is not None:
            for v in sg(inp, env):
                acc = us(acc, (name, v, env))
            return acc
        for v in sg(inp, env):
            env2 = (name, v, env)
            last = None
            for last in ug(acc, env2):
                pass
            acc = last
        return acc

    if init.single is not None:
        i_s = init.single
        return from_single(lambda inp, env: run(i_s(inp, env), inp, env))

    def gen(inp, env):
        for acc in init.gen(inp, env):
            yield run(acc, inp, env)

    return from_gen(gen)


def _call(node, scope):
    from .builtins import BUILTINS

    entry = BUILTINS.get((node.name, len(node.args)))
    if entry is None:
        raise JQSyntaxError(f"{node.name}/{len(node.args)} is not defined")
    args = [compile_node(a, scope) for a in node.args]
    return entry(*args)


_DISPATCH = {
    ast.Identity: _identity,
    ast.Literal: _literal,
    ast.Var: _var,
    ast.Index: _index,
    ast.Slice: _slice,
    ast.Iterate: _iterate,
    ast.Try: _try,
    ast.Pipe: _pipe,
    ast.Comma: _comma,
    ast.BinOp: _binop,
    ast.And: _and,
    ast.Or: _or,
    ast.Neg: _neg,
    ast.ArrayCons: _array,
    ast.ObjectCons: _object,
    ast.If: _if,
    ast.As: _as,
    ast.Reduce: _reduce,
    ast.Call: _call,
}
