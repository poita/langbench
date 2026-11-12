"""Exceptions raised by the Datalog library."""

from __future__ import annotations


class DatalogError(Exception):
    """Base class of every error the library raises on purpose."""


class ParseError(DatalogError):
    """The program text is not syntactically valid."""


class UnsafeRuleError(DatalogError):
    """A rule has a variable that no positive body atom binds."""


class StratificationError(DatalogError):
    """A predicate depends on itself through negation."""
