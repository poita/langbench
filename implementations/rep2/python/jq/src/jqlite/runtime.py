"""Compiled-filter representation shared by the compiler and the builtins.

A compiled filter is a :class:`Code` holding

* ``gen(inp, env)``: returns an iterable of the filter's outputs for input
  ``inp``; evaluation is lazy and a :class:`~jqlite.errors.JQError` surfaces at
  the point it occurs;
* ``single(inp, env)``: only for filters statically known to yield exactly one
  output (or raise): returns that output directly, avoiding generator
  overhead.  ``None`` otherwise.

``env`` is the persistent variable environment: ``None`` or a linked tuple
``(name, value, parent)``.
"""

from __future__ import annotations

from typing import Any, Callable, Iterable, Optional

Gen = Callable[[Any, Any], Iterable[Any]]
Single = Callable[[Any, Any], Any]


class Code:
    __slots__ = ("gen", "single")

    def __init__(self, gen: Gen, single: Optional[Single] = None) -> None:
        self.gen = gen
        self.single = single


def from_single(s: Single) -> Code:
    def gen(inp, env):
        return (s(inp, env),)

    return Code(gen, s)


def from_gen(g: Gen) -> Code:
    return Code(g, None)
