"""Exception types raised by jqlite."""

from __future__ import annotations


class JQError(Exception):
    """A runtime error raised while evaluating a filter.

    This is the error that ``?`` / ``try`` swallow.  ``value`` is the jq value
    carried by the error (the message string for built-in errors, or whatever
    was passed to ``error(f)``).
    """

    def __init__(self, value: object = None) -> None:
        super().__init__(value)
        self.value = value

    def __str__(self) -> str:
        v = self.value
        if isinstance(v, str):
            return v
        from .jsonio import dumps

        try:
            return dumps(v) + " (not a string)"
        except Exception:  # pragma: no cover - defensive
            return repr(v)


class JQSyntaxError(Exception):
    """The filter text is not valid in the supported jq subset."""


class JSONDecodeError(ValueError):
    """The JSON text is malformed."""
