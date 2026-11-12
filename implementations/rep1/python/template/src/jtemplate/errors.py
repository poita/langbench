"""Exception hierarchy for the template engine.

Every failure the engine can report is a :class:`TemplateError` carrying a
short machine-readable :attr:`~TemplateError.kind`.  The command-line tool
prints ``error: <kind>`` for it.
"""

from __future__ import annotations


class TemplateError(Exception):
    """Base class of every error raised while loading or rendering."""

    #: Short identifier of the error category (``"syntax"``, ``"filter"``, ...).
    kind: str = "error"

    def __init__(self, message: str = "") -> None:
        super().__init__(message or self.kind)
        self.message = message or self.kind


class TemplateSyntaxError(TemplateError):
    """The template text cannot be lexed or parsed."""

    kind = "syntax"


class UnknownFilterError(TemplateError):
    """A loaded template names a filter that does not exist."""

    kind = "filter"


class UndefinedValueError(TemplateError):
    """The undefined value was used in a forbidden way."""

    kind = "undefined"


class TemplateNotFoundError(TemplateError):
    """``include`` or ``extends`` named a template that does not exist."""

    kind = "template"


class TemplateTypeError(TemplateError):
    """An operand, argument or call target had the wrong kind or arity."""

    kind = "type"
