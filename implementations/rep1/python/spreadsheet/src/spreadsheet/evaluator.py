"""Formula evaluator: walks a syntax tree against stored cell values.

References and ranges read the *stored* value of the cells they name; they
never trigger evaluation of those cells.  Scheduling (dependencies first) is
the job of :mod:`spreadsheet.sheet`.
"""

from __future__ import annotations

from math import isfinite
from typing import Any, Callable, Mapping

from . import syntax as ast
from .formatting import format_number
from .values import DIV0, VALUE, CellError, Value

__all__ = ["evaluate"]


def evaluate(node: ast.Node, cells: Mapping[int, Any]) -> Value:
    """Evaluate *node*; *cells* maps keys to objects with a ``value`` attribute.

    The result is a float, string, error, or ``None`` for *empty*; callers
    turn a whole-formula ``None`` into the number 0.
    """
    return _DISPATCH[type(node)](node, cells)


def _number(v: Value) -> float | CellError:
    """Coerce an operand for arithmetic: errors pass, strings fail, empty is 0."""
    if v is None:
        return 0.0
    if isinstance(v, str):
        return VALUE
    return v


def _text(v: Value) -> str:
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    return format_number(v)


def _literal(node: ast.Literal, cells: Mapping[int, Any]) -> Value:
    return node.value


def _ref(node: ast.Ref, cells: Mapping[int, Any]) -> Value:
    cell = cells.get(node.key)
    return None if cell is None else cell.value


def _neg(node: ast.Neg, cells: Mapping[int, Any]) -> Value:
    v = _number(evaluate(node.operand, cells))
    if isinstance(v, CellError):
        return v
    return -v


def _arith(node: ast.Arith, cells: Mapping[int, Any]) -> Value:
    a = _number(evaluate(node.left, cells))
    if isinstance(a, CellError):
        return a
    b = _number(evaluate(node.right, cells))
    if isinstance(b, CellError):
        return b
    op = node.op
    if op == "+":
        r = a + b
    elif op == "-":
        r = a - b
    elif op == "*":
        r = a * b
    else:
        if b == 0:
            return DIV0
        r = a / b
    return r if isfinite(r) else VALUE


def _concat(node: ast.Concat, cells: Mapping[int, Any]) -> Value:
    a = evaluate(node.left, cells)
    if isinstance(a, CellError):
        return a
    b = evaluate(node.right, cells)
    if isinstance(b, CellError):
        return b
    return _text(a) + _text(b)


_COMPARATORS: dict[str, Callable[[Any, Any], bool]] = {
    "=": lambda a, b: a == b,
    "<>": lambda a, b: a != b,
    "<": lambda a, b: a < b,
    ">": lambda a, b: a > b,
    "<=": lambda a, b: a <= b,
    ">=": lambda a, b: a >= b,
}


def _compare(node: ast.Compare, cells: Mapping[int, Any]) -> Value:
    a = evaluate(node.left, cells)
    if isinstance(a, CellError):
        return a
    b = evaluate(node.right, cells)
    if isinstance(b, CellError):
        return b
    if a is None:
        a = 0.0 if b is None or not isinstance(b, str) else ""
    if b is None:
        b = 0.0 if not isinstance(a, str) else ""
    if isinstance(a, str) != isinstance(b, str):
        # Mixed number/string: never converted.
        if node.op == "=":
            return 0.0
        if node.op == "<>":
            return 1.0
        return VALUE
    # Python compares str by code point, which is what the spec requires.
    return 1.0 if _COMPARATORS[node.op](a, b) else 0.0


def _if(node: ast.If, cells: Mapping[int, Any]) -> Value:
    c = _number(evaluate(node.cond, cells))
    if isinstance(c, CellError):
        return c
    return evaluate(node.then if c != 0 else node.otherwise, cells)


def _aggregate(node: ast.Aggregate, cells: Mapping[int, Any]) -> Value:
    nums: list[float] = []
    for arg in node.args:
        if type(arg) is ast.Range:
            for row in range(arg.row1, arg.row2 + 1):
                base = row << 10
                for col in range(arg.col1, arg.col2 + 1):
                    cell = cells.get(base | col)
                    if cell is None:
                        continue
                    v = cell.value
                    if isinstance(v, str):
                        continue
                    if isinstance(v, CellError):
                        return v
                    nums.append(v)
        else:
            v = evaluate(arg, cells)
            if isinstance(v, CellError):
                return v
            if isinstance(v, str):
                return VALUE
            if v is not None:
                nums.append(v)
    func = node.func
    if func == "COUNT":
        return float(len(nums))
    if func == "MIN":
        return min(nums) if nums else 0.0
    if func == "MAX":
        return max(nums) if nums else 0.0
    # SUM / AVG: add left to right (sum() would use compensated summation).
    total = 0.0
    for x in nums:
        total += x
    if func == "SUM":
        return total if isfinite(total) else VALUE
    if not nums:
        return DIV0
    if not isfinite(total):
        return VALUE
    avg = total / len(nums)
    return avg if isfinite(avg) else VALUE


_DISPATCH: dict[type, Callable[[Any, Mapping[int, Any]], Value]] = {
    ast.Literal: _literal,
    ast.Ref: _ref,
    ast.Neg: _neg,
    ast.Arith: _arith,
    ast.Concat: _concat,
    ast.Compare: _compare,
    ast.If: _if,
    ast.Aggregate: _aggregate,
}
