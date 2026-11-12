"""The primitive procedures of the initial global environment.

Each primitive is a plain Python function carrying ``lo``/``hi`` attributes
(its minimum and maximum argument count; ``hi`` is ``None`` for variadic
primitives).  Fixed-arity primitives rely on Python's own argument-count
check (the evaluator turns the resulting ``TypeError`` into ``arity-error``);
variadic primitives check their minimum themselves.  Arguments are
type-checked after arity, and all of them before any work is done.
"""

from __future__ import annotations

from typing import Any, Callable, Optional

from . import bignum
from .bignum import BigInt, SMALL_LIMIT, MUL_LIMIT
from .errors import SchemeError
from .printer import display_string
from .values import NIL, VOID, Closure, Pair, PrimitiveType, Symbol, intern


def _type_error() -> SchemeError:
    return SchemeError("type-error")


def _arity_error() -> SchemeError:
    return SchemeError("arity-error")


def _check_numbers(args: tuple) -> None:
    for x in args:
        t = type(x)
        if t is not int and t is not BigInt:
            raise _type_error()


def _is_number(x: Any) -> bool:
    t = type(x)
    return t is int or t is BigInt


# --- arithmetic --------------------------------------------------------------


def add(*args: Any) -> Any:
    if len(args) == 2:
        a, b = args
        if type(a) is int and type(b) is int:
            r = a + b
            if -SMALL_LIMIT < r < SMALL_LIMIT:
                return r
            return bignum.from_word(r)
    _check_numbers(args)
    acc: Any = 0
    for x in args:
        acc = bignum.add(acc, x)
    return acc


def mul(*args: Any) -> Any:
    if len(args) == 2:
        a, b = args
        if (
            type(a) is int
            and type(b) is int
            and -MUL_LIMIT < a < MUL_LIMIT
            and -MUL_LIMIT < b < MUL_LIMIT
        ):
            return a * b
    _check_numbers(args)
    acc: Any = 1
    for x in args:
        acc = bignum.mul(acc, x)
    return acc


def sub(*args: Any) -> Any:
    n = len(args)
    if n == 2:
        a, b = args
        if type(a) is int and type(b) is int:
            r = a - b
            if -SMALL_LIMIT < r < SMALL_LIMIT:
                return r
            return bignum.from_word(r)
    if n == 0:
        raise _arity_error()
    _check_numbers(args)
    if n == 1:
        return bignum.neg(args[0])
    acc = args[0]
    for x in args[1:]:
        acc = bignum.sub(acc, x)
    return acc


def _division(a: Any, b: Any) -> tuple[Any, Any]:
    if not (_is_number(a) and _is_number(b)):
        raise _type_error()
    if b == 0 and type(b) is int:
        raise SchemeError("division-by-zero")
    return bignum.divmod_trunc(a, b)


def quotient(a: Any, b: Any) -> Any:
    return _division(a, b)[0]


def remainder(a: Any, b: Any) -> Any:
    return _division(a, b)[1]


def _chain(args: tuple, holds: Callable[[int], bool]) -> bool:
    if len(args) < 2:
        raise _arity_error()
    _check_numbers(args)
    for i in range(len(args) - 1):
        if not holds(bignum.compare(args[i], args[i + 1])):
            return False
    return True


def num_eq(*args: Any) -> bool:
    if len(args) == 2:
        a, b = args
        if type(a) is int and type(b) is int:
            return a == b
    return _chain(args, lambda c: c == 0)


def num_lt(*args: Any) -> bool:
    if len(args) == 2:
        a, b = args
        if type(a) is int and type(b) is int:
            return a < b
    return _chain(args, lambda c: c < 0)


def num_gt(*args: Any) -> bool:
    if len(args) == 2:
        a, b = args
        if type(a) is int and type(b) is int:
            return a > b
    return _chain(args, lambda c: c > 0)


def num_le(*args: Any) -> bool:
    if len(args) == 2:
        a, b = args
        if type(a) is int and type(b) is int:
            return a <= b
    return _chain(args, lambda c: c <= 0)


def num_ge(*args: Any) -> bool:
    if len(args) == 2:
        a, b = args
        if type(a) is int and type(b) is int:
            return a >= b
    return _chain(args, lambda c: c >= 0)


# --- pairs and lists ---------------------------------------------------------


def cons(a: Any, d: Any) -> Pair:
    return Pair(a, d)


def car(p: Any) -> Any:
    if type(p) is Pair:
        return p.car
    raise _type_error()


def cdr(p: Any) -> Any:
    if type(p) is Pair:
        return p.cdr
    raise _type_error()


def list_(*args: Any) -> Any:
    result = NIL
    for x in reversed(args):
        result = Pair(x, result)
    return result


def null_p(x: Any) -> bool:
    return x is NIL


def pair_p(x: Any) -> bool:
    return type(x) is Pair


# --- predicates and equivalence ---------------------------------------------


def not_(x: Any) -> bool:
    return x is False


def number_p(x: Any) -> bool:
    return _is_number(x)


def boolean_p(x: Any) -> bool:
    return type(x) is bool


def string_p(x: Any) -> bool:
    return type(x) is str


def symbol_p(x: Any) -> bool:
    return type(x) is Symbol


def procedure_p(x: Any) -> bool:
    t = type(x)
    return t is Closure or t is PrimitiveType


def eq_p(a: Any, b: Any) -> bool:
    ta = type(a)
    if ta is int:
        return type(b) is int and a == b
    if ta is BigInt:
        return type(b) is BigInt and bignum.compare(a, b) == 0
    return a is b


def equal_p(a: Any, b: Any) -> bool:
    while True:
        if type(a) is Pair:
            if type(b) is not Pair:
                return False
            if not equal_p(a.car, b.car):
                return False
            a = a.cdr
            b = b.cdr
            continue
        if type(a) is str:
            return type(b) is str and a == b
        return eq_p(a, b)


# --- control -----------------------------------------------------------------


def apply(f: Any, *rest: Any) -> Any:
    """Returns a tail-call request ``(f, args)`` for the trampoline."""
    if not rest:
        raise _arity_error()
    args = list(rest[:-1])
    lst = rest[-1]
    while type(lst) is Pair:
        args.append(lst.car)
        lst = lst.cdr
    if lst is not NIL:
        raise _type_error()
    return (f, tuple(args))


def error(*args: Any) -> Any:
    raise SchemeError("user-error")


# --- strings and symbols -----------------------------------------------------


def string_append(*args: Any) -> str:
    for s in args:
        if type(s) is not str:
            raise _type_error()
    return "".join(args)


def string_length(s: Any) -> int:
    if type(s) is not str:
        raise _type_error()
    return len(s)


def number_to_string(n: Any) -> str:
    if not _is_number(n):
        raise _type_error()
    return bignum.to_string(n)


def symbol_to_string(s: Any) -> str:
    if type(s) is not Symbol:
        raise _type_error()
    return s.name


# --- registry ----------------------------------------------------------------

_ARITY: dict[str, tuple[int, Optional[int]]] = {
    "+": (0, None), "*": (0, None), "-": (1, None),
    "quotient": (2, 2), "remainder": (2, 2),
    "=": (2, None), "<": (2, None), ">": (2, None), "<=": (2, None), ">=": (2, None),
    "cons": (2, 2), "car": (1, 1), "cdr": (1, 1), "list": (0, None),
    "null?": (1, 1), "pair?": (1, 1),
    "not": (1, 1), "number?": (1, 1), "boolean?": (1, 1), "string?": (1, 1),
    "symbol?": (1, 1), "procedure?": (1, 1), "eq?": (2, 2), "equal?": (2, 2),
    "apply": (2, None), "error": (0, None),
    "string-append": (0, None), "string-length": (1, 1),
    "number->string": (1, 1), "symbol->string": (1, 1),
    "display": (1, 1), "newline": (0, 0),
}  # fmt: skip

_FUNCTIONS: dict[str, Callable[..., Any]] = {
    "+": add, "*": mul, "-": sub,
    "quotient": quotient, "remainder": remainder,
    "=": num_eq, "<": num_lt, ">": num_gt, "<=": num_le, ">=": num_ge,
    "cons": cons, "car": car, "cdr": cdr, "list": list_,
    "null?": null_p, "pair?": pair_p,
    "not": not_, "number?": number_p, "boolean?": boolean_p, "string?": string_p,
    "symbol?": symbol_p, "procedure?": procedure_p, "eq?": eq_p, "equal?": equal_p,
    "apply": apply, "error": error,
    "string-append": string_append, "string-length": string_length,
    "number->string": number_to_string, "symbol->string": symbol_to_string,
}  # fmt: skip


def make_primitives(write: Callable[[str], Any]) -> dict[Symbol, Callable[..., Any]]:
    """Build the primitive table; ``write`` receives all program output."""

    def display(x: Any) -> Any:
        write(display_string(x))
        return VOID

    def newline() -> Any:
        write("\n")
        return VOID

    funcs = dict(_FUNCTIONS)
    funcs["display"] = display
    funcs["newline"] = newline
    table = {}
    for name, fn in funcs.items():
        fn.lo, fn.hi = _ARITY[name]
        table[intern(name)] = fn
    return table
