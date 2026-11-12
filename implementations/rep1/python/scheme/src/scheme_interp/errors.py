"""Exception types raised by the interpreter."""

from __future__ import annotations


class SchemeError(Exception):
    """A runtime error of the interpreted program.

    ``category`` is one of the category names the specification defines:
    ``unbound-variable``, ``type-error``, ``arity-error``,
    ``division-by-zero`` or ``user-error``.
    """

    def __init__(self, category: str) -> None:
        super().__init__(category)
        self.category = category


class SchemeSyntaxError(SchemeError):
    """Malformed source text or a malformed special form.

    The specification does not define behaviour for these; the command-line
    tool reports them as ``error: syntax-error``.
    """

    def __init__(self, message: str = "") -> None:
        super().__init__("syntax-error")
        self.message = message
