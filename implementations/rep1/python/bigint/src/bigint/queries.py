"""Evaluation of ``"<a> <op> <b>"`` query lines."""

from __future__ import annotations

from collections.abc import Iterable, Iterator

from .integer import BigInt

OPERATORS = ("+", "-", "*", "/", "%", "^", "cmp")


class QueryError(Exception):
    """A well-formed query with no result (division by zero, negative exponent)."""


def evaluate_query(line: str) -> str:
    """Evaluate one query line and return the output text (no newline).

    Raises :class:`QueryError` for division or remainder by zero and for a
    negative exponent, and :class:`ValueError` for a malformed line.
    """
    parts = line.split(" ")
    if len(parts) != 3 or parts[1] not in OPERATORS:
        raise ValueError(f"malformed query: {line[:60]!r}")
    a = BigInt.parse(parts[0])
    op = parts[1]
    b = BigInt.parse(parts[2])
    try:
        if op == "+":
            return str(a + b)
        if op == "-":
            return str(a - b)
        if op == "*":
            return str(a * b)
        if op == "/":
            return str(a.quotient(b))
        if op == "%":
            return str(a.remainder(b))
        if op == "^":
            return str(a**b)
        return str(a.compare(b))
    except (ZeroDivisionError, ValueError) as exc:
        raise QueryError(str(exc)) from exc


def evaluate_queries(lines: Iterable[str]) -> Iterator[str]:
    """Yield one output line per query; ``"error"`` for :class:`QueryError` cases."""
    for line in lines:
        try:
            yield evaluate_query(line)
        except QueryError:
            yield "error"
