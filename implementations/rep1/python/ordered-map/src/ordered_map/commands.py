"""Interpreter for the line-oriented command language (see the README)."""

from __future__ import annotations

from collections.abc import Iterable, Iterator

from .ordered_map import OrderedMap

MISSING = "missing"
EMPTY = "empty"


def _key_or(value: int | None, fallback: str) -> str:
    return fallback if value is None else str(value)


def execute(omap: OrderedMap, line: str) -> str:
    """Execute one command line against ``omap`` and return its output line."""
    parts = line.split(" ")
    op = parts[0]
    if op == "insert":
        return "ok" if omap.insert(int(parts[1]), parts[2]) else "updated"
    if op == "get":
        value = omap.get(int(parts[1]))
        return MISSING if value is None else value
    if op == "delete":
        return "ok" if omap.delete(int(parts[1])) else MISSING
    if op == "size":
        return str(len(omap))
    if op == "min":
        return _key_or(omap.min(), EMPTY)
    if op == "max":
        return _key_or(omap.max(), EMPTY)
    if op == "floor":
        return _key_or(omap.floor(int(parts[1])), MISSING)
    if op == "ceil":
        return _key_or(omap.ceil(int(parts[1])), MISSING)
    if op == "succ":
        return _key_or(omap.successor(int(parts[1])), MISSING)
    if op == "pred":
        return _key_or(omap.predecessor(int(parts[1])), MISSING)
    if op == "rank":
        return str(omap.rank(int(parts[1])))
    if op == "select":
        return _key_or(omap.select(int(parts[1])), MISSING)
    if op == "range":
        lo, hi = int(parts[1]), int(parts[2])
        if lo > hi:
            return EMPTY
        return " ".join(map(str, omap.range(lo, hi))) or EMPTY
    raise ValueError(f"unknown command: {line!r}")


def run(lines: Iterable[str], omap: OrderedMap | None = None) -> Iterator[str]:
    """Execute each command line in turn, yielding one output line each."""
    if omap is None:
        omap = OrderedMap()
    for line in lines:
        yield execute(omap, line)
