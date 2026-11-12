"""Exceptions shared by every phase: compile-time diagnostics and run-time panics."""

from __future__ import annotations


class CompileError(Exception):
    """A rejected program.  Renders as ``error: <kind> at <line>:<col>``."""

    def __init__(self, kind: str, line: int, col: int):
        super().__init__(kind, line, col)
        self.kind = kind
        self.line = line
        self.col = col

    def render(self) -> str:
        return f"error: {self.kind} at {self.line}:{self.col}"

    __str__ = render


def error(kind: str, pos: tuple[int, int]) -> CompileError:
    """Build a :class:`CompileError` for a ``(line, col)`` position."""
    return CompileError(kind, pos[0], pos[1])


class Panic(Exception):
    """A run-time panic; ``message`` is printed after ``panic: ``."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message
