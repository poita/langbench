"""Command-line tool: evaluate one ``<a> <op> <b>`` query per input line."""

from __future__ import annotations

import sys
from typing import Callable, Iterable, Iterator

from .number import BigInt

ERROR = "error"

_OPS: dict[str, Callable[[BigInt, BigInt], object]] = {
    "+": lambda a, b: a + b,
    "-": lambda a, b: a - b,
    "*": lambda a, b: a * b,
    "/": BigInt.div_trunc,
    "%": BigInt.rem_trunc,
    "^": BigInt.pow,
    "cmp": BigInt.compare,
}


def evaluate(line: str) -> str:
    """Evaluate one query line and return its output line (without newline)."""
    a_text, op, b_text = line.split(" ")
    try:
        result = _OPS[op](BigInt.parse(a_text), BigInt.parse(b_text))
    except (ZeroDivisionError, ValueError):
        # Division by zero, or a negative exponent.
        return ERROR
    return str(result)


def evaluate_all(lines: Iterable[str]) -> Iterator[str]:
    """Evaluate each query line, yielding one result line per query."""
    for line in lines:
        yield evaluate(line)


def main(argv: list[str] | None = None) -> int:
    """Read queries from stdin and write one result per line to stdout."""
    text = sys.stdin.buffer.read().decode("utf-8")
    out = sys.stdout
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()  # the final newline is optional
    results = list(evaluate_all(lines))
    if results:
        out.write("\n".join(results) + "\n")
    out.flush()
    return 0
