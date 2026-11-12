"""Bound expression trees and their interpreter.

The binder turns syntax trees into these nodes, with every column reference
resolved to a position in the row being evaluated. Evaluation is a plain
recursive walk: ``node.eval(row, aggs)``. ``row`` is a tuple of values and
``aggs`` the list of aggregate results of the current group (or ``None``
outside an aggregate query).
"""

from __future__ import annotations

from typing import Callable, Sequence

from .like import like_match
from .values import Value, average, compare, format_value, truth


class Expr:
    """Base class of bound expressions."""

    __slots__ = ()

    def eval(self, row: Sequence[Value], aggs: Sequence[Value] | None) -> Value:
        raise NotImplementedError


class Literal(Expr):
    __slots__ = ("value",)

    def __init__(self, value: Value) -> None:
        self.value = value

    def eval(self, row, aggs):
        return self.value


class Column(Expr):
    __slots__ = ("index",)

    def __init__(self, index: int) -> None:
        self.index = index

    def eval(self, row, aggs):
        return row[self.index]


class Negate(Expr):
    __slots__ = ("operand",)

    def __init__(self, operand: Expr) -> None:
        self.operand = operand

    def eval(self, row, aggs):
        v = self.operand.eval(row, aggs)
        return None if v is None else -v


class Not(Expr):
    __slots__ = ("operand",)

    def __init__(self, operand: Expr) -> None:
        self.operand = operand

    def eval(self, row, aggs):
        t = truth(self.operand.eval(row, aggs))
        if t is None:
            return None
        return 0 if t else 1


class And(Expr):
    __slots__ = ("left", "right")

    def __init__(self, left: Expr, right: Expr) -> None:
        self.left = left
        self.right = right

    def eval(self, row, aggs):
        a = truth(self.left.eval(row, aggs))
        if a is False:
            return 0
        b = truth(self.right.eval(row, aggs))
        if b is False:
            return 0
        if a is None or b is None:
            return None
        return 1


class Or(Expr):
    __slots__ = ("left", "right")

    def __init__(self, left: Expr, right: Expr) -> None:
        self.left = left
        self.right = right

    def eval(self, row, aggs):
        a = truth(self.left.eval(row, aggs))
        if a is True:
            return 1
        b = truth(self.right.eval(row, aggs))
        if b is True:
            return 1
        if a is None or b is None:
            return None
        return 0


def _div(a: int, b: int) -> int | None:
    """Integer division truncating toward zero; NULL on division by zero."""
    if b == 0:
        return None
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def _mod(a: int, b: int) -> int | None:
    """Remainder with the sign of the dividend; NULL on division by zero."""
    if b == 0:
        return None
    r = abs(a) % abs(b)
    return -r if a < 0 else r


_ARITHMETIC: dict[str, Callable[[int, int], int | None]] = {
    "+": lambda a, b: a + b,
    "-": lambda a, b: a - b,
    "*": lambda a, b: a * b,
    "/": _div,
    "%": _mod,
}

_COMPARISONS: dict[str, Callable[[int], bool]] = {
    "=": lambda c: c == 0,
    "!=": lambda c: c != 0,
    "<": lambda c: c < 0,
    "<=": lambda c: c <= 0,
    ">": lambda c: c > 0,
    ">=": lambda c: c >= 0,
}


class Arithmetic(Expr):
    __slots__ = ("fn", "left", "right")

    def __init__(self, op: str, left: Expr, right: Expr) -> None:
        self.fn = _ARITHMETIC[op]
        self.left = left
        self.right = right

    def eval(self, row, aggs):
        a = self.left.eval(row, aggs)
        b = self.right.eval(row, aggs)
        if a is None or b is None:
            return None
        return self.fn(a, b)


class Compare(Expr):
    __slots__ = ("test", "left", "right")

    def __init__(self, op: str, left: Expr, right: Expr) -> None:
        self.test = _COMPARISONS[op]
        self.left = left
        self.right = right

    def eval(self, row, aggs):
        a = self.left.eval(row, aggs)
        b = self.right.eval(row, aggs)
        if a is None or b is None:
            return None
        return 1 if self.test(compare(a, b)) else 0


class IsNull(Expr):
    __slots__ = ("operand", "negated")

    def __init__(self, operand: Expr, negated: bool) -> None:
        self.operand = operand
        self.negated = negated

    def eval(self, row, aggs):
        is_null = self.operand.eval(row, aggs) is None
        return 1 if is_null != self.negated else 0


class Like(Expr):
    __slots__ = ("operand", "pattern")

    def __init__(self, operand: Expr, pattern: Expr) -> None:
        self.operand = operand
        self.pattern = pattern

    def eval(self, row, aggs):
        a = self.operand.eval(row, aggs)
        b = self.pattern.eval(row, aggs)
        if a is None or b is None:
            return None
        text = a if type(a) is str else format_value(a)
        pat = b if type(b) is str else format_value(b)
        return 1 if like_match(text, pat) else 0


class AggregateRef(Expr):
    """Reads the result of the ``slot``-th aggregate of the current group."""

    __slots__ = ("slot",)

    def __init__(self, slot: int) -> None:
        self.slot = slot

    def eval(self, row, aggs):
        return aggs[self.slot]  # type: ignore[index]


class AggregateSpec:
    """An aggregate call: function name and argument (None for ``COUNT(*)``)."""

    __slots__ = ("func", "arg")

    def __init__(self, func: str, arg: Expr | None) -> None:
        self.func = func
        self.arg = arg

    def compute(self, rows: Sequence[Sequence[Value]]) -> Value:
        """Evaluate the aggregate over the rows of one group."""
        func = self.func
        if self.arg is None:  # COUNT(*)
            return len(rows)
        arg = self.arg
        values = [v for v in (arg.eval(r, None) for r in rows) if v is not None]
        if func == "count":
            return len(values)
        if not values:
            return None
        if func == "sum":
            return sum(values)  # type: ignore[arg-type]
        if func == "avg":
            return average(sum(values), len(values))  # type: ignore[arg-type]
        best = values[0]
        if func == "min":
            for v in values:
                if compare(v, best) < 0:
                    best = v
        else:
            for v in values:
                if compare(v, best) > 0:
                    best = v
        return best

