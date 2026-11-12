"""Binary and unary operators of the expression language.

Every function takes already evaluated operands.  The undefined value is
rejected first (an ``undefined`` error), then operand kinds are checked (a
``type`` error).
"""

from __future__ import annotations

import operator
from typing import Any, Callable

from .errors import TemplateTypeError, UndefinedValueError
from .values import UNDEFINED, is_number, to_str, type_name


def _no_undefined(a: Any, b: Any) -> None:
    if a is UNDEFINED or b is UNDEFINED:
        raise UndefinedValueError("undefined value used in operator")


def _bad(op: str, a: Any, b: Any) -> TemplateTypeError:
    return TemplateTypeError(f"unsupported operands for {op}: {type_name(a)}, {type_name(b)}")


def add(a: Any, b: Any) -> Any:
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        return a + b
    if isinstance(a, str) and isinstance(b, str):
        return a + b
    if isinstance(a, list) and isinstance(b, list):
        return a + b
    raise _bad("+", a, b)


def sub(a: Any, b: Any) -> Any:
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        return a - b
    raise _bad("-", a, b)


def neg(a: Any) -> Any:
    if a is UNDEFINED:
        raise UndefinedValueError("undefined value used in operator")
    if is_number(a):
        return -a
    raise TemplateTypeError(f"cannot negate {type_name(a)}")


def mul(a: Any, b: Any) -> Any:
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        return a * b
    if isinstance(a, str) and isinstance(b, int):
        return a * b if b > 0 else ""
    if isinstance(a, int) and isinstance(b, str):
        return b * a if a > 0 else ""
    raise _bad("*", a, b)


def div(a: Any, b: Any) -> Any:
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        if b == 0:
            raise TemplateTypeError("division by zero")
        return a / b
    raise _bad("/", a, b)


def floordiv(a: Any, b: Any) -> Any:
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        if b == 0:
            raise TemplateTypeError("division by zero")
        return a // b
    raise _bad("//", a, b)


def mod(a: Any, b: Any) -> Any:
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        if b == 0:
            raise TemplateTypeError("modulo by zero")
        return a % b
    raise _bad("%", a, b)


def power(a: Any, b: Any) -> Any:
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        try:
            result = a**b
        except (ZeroDivisionError, OverflowError) as exc:
            raise TemplateTypeError(f"invalid power: {exc}") from None
        if isinstance(result, complex):
            raise TemplateTypeError("power of negative float")
        return result
    raise _bad("**", a, b)


def concat(a: Any, b: Any) -> str:
    _no_undefined(a, b)
    return to_str(a) + to_str(b)


def _unify(a: Any, b: Any) -> tuple[Any, Any]:
    """Convert an integer to float when the other operand is a float."""
    if isinstance(a, float) and not isinstance(b, float):
        return a, float(b)
    if isinstance(b, float) and not isinstance(a, float):
        return float(a), b
    return a, b


def equal(a: Any, b: Any) -> bool:
    """``==``: never a type error."""
    _no_undefined(a, b)
    if is_number(a) and is_number(b):
        a, b = _unify(a, b)
    return a == b


def not_equal(a: Any, b: Any) -> bool:
    return not equal(a, b)


def _ordering(fn: Callable[[Any, Any], bool], symbol: str) -> Callable[[Any, Any], bool]:
    def compare(a: Any, b: Any) -> bool:
        _no_undefined(a, b)
        if is_number(a) and is_number(b):
            a, b = _unify(a, b)
            return fn(a, b)
        if isinstance(a, str) and isinstance(b, str):
            return fn(a, b)
        raise _bad(symbol, a, b)

    compare.__name__ = f"compare_{symbol}"
    return compare


less = _ordering(operator.lt, "<")
less_equal = _ordering(operator.le, "<=")
greater = _ordering(operator.gt, ">")
greater_equal = _ordering(operator.ge, ">=")


def contains(item: Any, container: Any) -> bool:
    """``item in container``."""
    _no_undefined(item, container)
    if isinstance(container, str):
        if not isinstance(item, str):
            raise TemplateTypeError("'in <string>' requires a string on the left")
        return item in container
    if isinstance(container, dict):
        return isinstance(item, str) and item in container
    if isinstance(container, list):
        return any(equal(element, item) for element in container)
    raise TemplateTypeError(f"cannot test membership in {type_name(container)}")


def not_contains(item: Any, container: Any) -> bool:
    return not contains(item, container)


#: Binary operators by token.
BINARY: dict[str, Callable[[Any, Any], Any]] = {
    "+": add,
    "-": sub,
    "*": mul,
    "/": div,
    "//": floordiv,
    "%": mod,
    "**": power,
    "~": concat,
}

#: Comparison operators by token (``not in`` is spelled ``"not in"``).
COMPARE: dict[str, Callable[[Any, Any], bool]] = {
    "==": equal,
    "!=": not_equal,
    "<": less,
    "<=": less_equal,
    ">": greater,
    ">=": greater_equal,
    "in": contains,
    "not in": not_contains,
}
