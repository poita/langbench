"""Exceptions raised by the parser and the type checker."""

from __future__ import annotations


class TypeInferError(Exception):
    """Base class of every exception raised by this package."""


class ParseError(TypeInferError):
    """The source text is not a well-formed program (lexing or parsing)."""

    def __init__(self, message: str, position: int = -1) -> None:
        super().__init__(message if position < 0 else f"{message} (at offset {position})")
        self.position = position


class TypeCheckError(TypeInferError):
    """A declaration does not type-check.

    ``kind`` is one of ``"unify"``, ``"occurs"`` or ``"unbound"`` and is what
    the command-line tool prints after ``error:``.
    """

    kind = "unify"

    def __init__(self, message: str | None = None) -> None:
        super().__init__(message or self.kind)


class UnifyError(TypeCheckError):
    """Two types with different shapes were unified."""

    kind = "unify"


class OccursError(TypeCheckError):
    """Unification would build an infinite type."""

    kind = "occurs"


class UnboundVariableError(TypeCheckError):
    """A variable is not in scope."""

    kind = "unbound"

    def __init__(self, name: str) -> None:
        super().__init__(f"unbound variable {name!r}")
        self.name = name
