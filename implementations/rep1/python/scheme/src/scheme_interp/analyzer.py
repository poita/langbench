"""The analyser: turns a datum into a tree of Python closures, once.

``analyze(datum, tail)`` returns a function ``node(env)`` that evaluates the
form in the frame ``env`` (a ``dict`` mapping :class:`Symbol` to value, with
the parent frame stored under the key :data:`PARENT`).  Variables are looked
up by name at run time, innermost frame first.

When ``tail`` is true, an application node returns a ``(procedure, args)``
tuple for :func:`scheme_interp.evaluator.call` to perform, instead of
performing the call itself.
"""

from __future__ import annotations

from types import FunctionType
from typing import Any, Callable

from .errors import SchemeError, SchemeSyntaxError
from .evaluator import call, call_primitive
from .values import NIL, PARENT, VOID, Closure, Pair, Symbol, intern

Node = Callable[[dict], Any]

_ELSE = intern("else")


def _unbound() -> SchemeError:
    return SchemeError("unbound-variable")


def _items(x: Any, what: str) -> list[Any]:
    """Elements of a proper list in source code."""
    out = []
    while type(x) is Pair:
        out.append(x.car)
        x = x.cdr
    if x is not NIL:
        raise SchemeSyntaxError(f"improper list in {what}")
    return out


def analyze(x: Any, tail: bool = False) -> Node:
    """Analyse datum ``x``; ``tail`` says whether it is in tail position."""
    t = type(x)
    if t is Symbol:
        return _variable(x)
    if t is Pair:
        head = x.car
        if type(head) is Symbol:
            handler = _SPECIAL_FORMS.get(head)
            if handler is not None:
                return handler(x, tail)
        return _application(x, tail)
    if x is NIL:
        raise SchemeSyntaxError("illegal empty combination ()")
    return _constant(x)  # integers, booleans, strings


def _constant(v: Any) -> Node:
    def const(env: dict) -> Any:
        return v

    return const


def _variable(sym: Symbol) -> Node:
    def ref(env: dict) -> Any:
        while env is not None:
            if sym in env:
                return env[sym]
            env = env[PARENT]
        raise _unbound()

    return ref


# --- sequences -------------------------------------------------------------


def _sequence(forms: list[Any], tail: bool) -> Node:
    if not forms:
        raise SchemeSyntaxError("empty body")
    nodes = [analyze(f, False) for f in forms[:-1]]
    last = analyze(forms[-1], tail)
    if not nodes:
        return last
    if len(nodes) == 1:
        first = nodes[0]

        def seq2(env: dict) -> Any:
            first(env)
            return last(env)

        return seq2

    def seq(env: dict) -> Any:
        for n in nodes:
            n(env)
        return last(env)

    return seq


# --- special forms -----------------------------------------------------------


def _quote(x: Any, tail: bool) -> Node:
    return _constant(x.cdr.car)


def _if(x: Any, tail: bool) -> Node:
    parts = _items(x.cdr, "if")
    if len(parts) not in (2, 3):
        raise SchemeSyntaxError("bad if")
    test = analyze(parts[0], False)
    then = analyze(parts[1], tail)
    els = analyze(parts[2], tail) if len(parts) == 3 else _constant(VOID)

    def if_(env: dict) -> Any:
        if test(env) is not False:
            return then(env)
        return els(env)

    return if_


def _define(x: Any, tail: bool) -> Node:
    target = x.cdr.car
    if type(target) is Pair:
        name = target.car
        value = _make_lambda(target.cdr, _items(x.cdr.cdr, "define"))
    else:
        name = target
        rest = _items(x.cdr.cdr, "define")
        if len(rest) != 1:
            raise SchemeSyntaxError("bad define")
        value = analyze(rest[0], False)
    if type(name) is not Symbol:
        raise SchemeSyntaxError("define needs a symbol")

    def define(env: dict) -> Any:
        env[name] = value(env)
        return VOID

    return define


def _set(x: Any, tail: bool) -> Node:
    parts = _items(x.cdr, "set!")
    if len(parts) != 2 or type(parts[0]) is not Symbol:
        raise SchemeSyntaxError("bad set!")
    name = parts[0]
    value = analyze(parts[1], False)

    def set_(env: dict) -> Any:
        v = value(env)
        e = env
        while e is not None:
            if name in e:
                e[name] = v
                return VOID
            e = e[PARENT]
        raise _unbound()

    return set_


def _parse_params(params: Any) -> tuple[tuple[Symbol, ...], Any]:
    names = []
    while type(params) is Pair:
        if type(params.car) is not Symbol:
            raise SchemeSyntaxError("bad parameter")
        names.append(params.car)
        params = params.cdr
    if params is NIL:
        return tuple(names), None
    if type(params) is not Symbol:
        raise SchemeSyntaxError("bad parameter list")
    return tuple(names), params


def _make_lambda(params: Any, body_forms: list[Any]) -> Node:
    names, rest = _parse_params(params)
    body = _sequence(body_forms, True)

    def lambda_(env: dict) -> Any:
        return Closure(names, rest, body, env)

    return lambda_


def _lambda(x: Any, tail: bool) -> Node:
    return _make_lambda(x.cdr.car, _items(x.cdr.cdr, "lambda"))


def _bindings(spec: Any, what: str) -> list[tuple[Symbol, Node]]:
    out = []
    for b in _items(spec, what):
        parts = _items(b, what)
        if len(parts) != 2 or type(parts[0]) is not Symbol:
            raise SchemeSyntaxError(f"bad binding in {what}")
        out.append((parts[0], analyze(parts[1], False)))
    return out


def _let(x: Any, tail: bool) -> Node:
    if type(x.cdr.car) is Symbol:
        return _named_let(x, tail)
    bindings = _bindings(x.cdr.car, "let")
    body = _sequence(_items(x.cdr.cdr, "let"), tail)
    if len(bindings) == 1:
        (name, init), = bindings

        def let1(env: dict) -> Any:
            return body({name: init(env), PARENT: env})

        return let1

    def let(env: dict) -> Any:
        frame = {PARENT: env}
        for name, init in bindings:
            frame[name] = init(env)
        return body(frame)

    return let


def _named_let(x: Any, tail: bool) -> Node:
    name = x.cdr.car
    bindings = _bindings(x.cdr.cdr.car, "let")
    body = _sequence(_items(x.cdr.cdr.cdr, "let"), True)
    params = tuple(n for n, _ in bindings)
    inits = [i for _, i in bindings]

    def named_let(env: dict) -> Any:
        args = tuple([i(env) for i in inits])
        frame = {PARENT: env}
        proc = frame[name] = Closure(params, None, body, frame)
        if tail:
            return (proc, args)
        return call(proc, args)

    return named_let


def _let_star(x: Any, tail: bool) -> Node:
    bindings = _bindings(x.cdr.car, "let*")
    body = _sequence(_items(x.cdr.cdr, "let*"), tail)

    def let_star(env: dict) -> Any:
        for name, init in bindings:
            env = {name: init(env), PARENT: env}
        if not bindings:
            env = {PARENT: env}
        return body(env)

    return let_star


def _letrec(x: Any, tail: bool) -> Node:
    bindings = _bindings(x.cdr.car, "letrec")
    body = _sequence(_items(x.cdr.cdr, "letrec"), tail)

    def letrec(env: dict) -> Any:
        frame = {PARENT: env}
        for name, init in bindings:
            frame[name] = init(frame)
        return body(frame)

    return letrec


def _begin(x: Any, tail: bool) -> Node:
    return _sequence(_items(x.cdr, "begin"), tail)


def _cond(x: Any, tail: bool) -> Node:
    clauses: list[tuple[Node, Any]] = []
    for clause in _items(x.cdr, "cond"):
        parts = _items(clause, "cond")
        if not parts:
            raise SchemeSyntaxError("empty cond clause")
        if parts[0] is _ELSE:
            test = _constant(True)
        else:
            test = analyze(parts[0], False)
        body = _sequence(parts[1:], tail) if len(parts) > 1 else None
        clauses.append((test, body))

    def cond(env: dict) -> Any:
        for test, body in clauses:
            v = test(env)
            if v is not False:
                if body is None:
                    return v
                return body(env)
        return VOID

    return cond


def _and(x: Any, tail: bool) -> Node:
    forms = _items(x.cdr, "and")
    if not forms:
        return _constant(True)
    nodes = [analyze(f, False) for f in forms[:-1]]
    last = analyze(forms[-1], tail)

    def and_(env: dict) -> Any:
        for n in nodes:
            if n(env) is False:
                return False
        return last(env)

    return and_


def _or(x: Any, tail: bool) -> Node:
    forms = _items(x.cdr, "or")
    if not forms:
        return _constant(False)
    nodes = [analyze(f, False) for f in forms[:-1]]
    last = analyze(forms[-1], tail)

    def or_(env: dict) -> Any:
        for n in nodes:
            v = n(env)
            if v is not False:
                return v
        return last(env)

    return or_


_SPECIAL_FORMS: dict[Symbol, Callable[[Any, bool], Node]] = {
    intern("quote"): _quote,
    intern("if"): _if,
    intern("define"): _define,
    intern("set!"): _set,
    intern("lambda"): _lambda,
    intern("let"): _let,
    intern("let*"): _let_star,
    intern("letrec"): _letrec,
    intern("begin"): _begin,
    intern("cond"): _cond,
    intern("and"): _and,
    intern("or"): _or,
}


# --- applications ------------------------------------------------------------


def _application(x: Any, tail: bool) -> Node:
    fn = analyze(x.car, False)
    args = [analyze(a, False) for a in _items(x.cdr, "application")]
    n = len(args)
    if tail:
        return _tail_application(fn, args, n)
    if n == 0:

        def app0(env: dict) -> Any:
            return call(fn(env), ())

        return app0
    if n == 1:
        a0 = args[0]

        def app1(env: dict) -> Any:
            f = fn(env)
            return call(f, (a0(env),))

        return app1
    if n == 2:
        a0, a1 = args

        def app2(env: dict) -> Any:
            f = fn(env)
            x0 = a0(env)
            return call(f, (x0, a1(env)))

        return app2
    if n == 3:
        a0, a1, a2 = args

        def app3(env: dict) -> Any:
            f = fn(env)
            x0 = a0(env)
            x1 = a1(env)
            return call(f, (x0, x1, a2(env)))

        return app3

    def app(env: dict) -> Any:
        f = fn(env)
        return call(f, tuple([a(env) for a in args]))

    return app


def _dispatch_tail(f: Any, argv: tuple) -> Any:
    t = type(f)
    if t is Closure:
        return (f, argv)
    if t is FunctionType:
        return call_primitive(f, argv)
    raise SchemeError("type-error")


def _tail_application(fn: Node, args: list[Node], n: int) -> Node:
    if n == 1:
        a0 = args[0]

        def tapp1(env: dict) -> Any:
            f = fn(env)
            argv = (a0(env),)
            if type(f) is Closure:
                return (f, argv)
            return _dispatch_tail(f, argv)

        return tapp1
    if n == 2:
        a0, a1 = args

        def tapp2(env: dict) -> Any:
            f = fn(env)
            x0 = a0(env)
            argv = (x0, a1(env))
            if type(f) is Closure:
                return (f, argv)
            return _dispatch_tail(f, argv)

        return tapp2

    def tapp(env: dict) -> Any:
        f = fn(env)
        argv = tuple([a(env) for a in args])
        if type(f) is Closure:
            return (f, argv)
        return _dispatch_tail(f, argv)

    return tapp
