"""Procedure application and the tail-call trampoline.

Analysed code is a tree of Python closures ``node(env) -> value``.  A node
compiled in *tail position* may return a ``(procedure, args)`` tuple instead
of a value (Scheme values are never tuples); :func:`call` is the trampoline
that keeps applying such tail calls in a loop, so tail calls consume no host
stack.
"""

from __future__ import annotations

from types import FunctionType
from typing import Any

from .errors import SchemeError
from .values import NIL, PARENT, Closure, Pair


def call_primitive(f: Any, args: tuple) -> Any:
    """Apply a primitive, translating a Python arity mismatch to ``arity-error``.

    Primitives never re-enter the evaluator and raise :class:`SchemeError`
    themselves for bad arguments, so a ``TypeError`` can only come from
    calling with the wrong number of arguments.  The result may be a
    ``(procedure, args)`` tail-call request (only ``apply`` returns one).
    """
    try:
        return f(*args)
    except TypeError:
        n = len(args)
        hi = f.hi
        if n < f.lo or (hi is not None and n > hi):
            raise SchemeError("arity-error") from None
        raise


def call(f: Any, args: tuple) -> Any:
    """Apply ``f`` to ``args`` and run tail calls to completion."""
    while True:
        t = type(f)
        if t is Closure:
            params = f.params
            n = f.nparams
            if f.rest is None:
                if len(args) != n:
                    raise SchemeError("arity-error")
                if n == 1:
                    env = {params[0]: args[0], PARENT: f.env}
                elif n == 2:
                    env = {params[0]: args[0], params[1]: args[1], PARENT: f.env}
                elif n == 0:
                    env = {PARENT: f.env}
                else:
                    env = dict(zip(params, args))
                    env[PARENT] = f.env
            else:
                if len(args) < n:
                    raise SchemeError("arity-error")
                env = dict(zip(params, args))
                rest = NIL
                for i in range(len(args) - 1, n - 1, -1):
                    rest = Pair(args[i], rest)
                env[f.rest] = rest
                env[PARENT] = f.env
            r = f.body(env)
        elif t is FunctionType:
            r = call_primitive(f, args)
        else:
            raise SchemeError("type-error")
        if type(r) is tuple:
            f, args = r
        else:
            return r
