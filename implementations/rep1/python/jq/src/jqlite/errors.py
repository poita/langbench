"""Exception types raised by jqlite."""

from __future__ import annotations


class JQError(Exception):
    """A runtime error raised while evaluating a filter.

    ``value`` carries the jq value the error was raised with (the argument of
    ``error(f)``, or the offending input for built-in failures).
    """

    def __init__(self, message: str = "error", value: object = None) -> None:
        super().__init__(message)
        self.value = value


class JQSyntaxError(Exception):
    """The filter text is not valid in the supported jq subset."""


class JSONDecodeError(ValueError):
    """The input document is not valid JSON."""
