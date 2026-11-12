"""Error types raised by the template engine.

Every error carries a :attr:`~TemplateError.kind`, one of ``syntax``,
``filter``, ``undefined``, ``template`` and ``type``.
"""

from __future__ import annotations

from ..errors import SitegenError


class TemplateError(SitegenError):
    """Base class of all template errors."""

    kind = "template"

    def __init__(self, message: str = "") -> None:
        super().__init__(message or self.kind)


class TemplateSyntaxError(TemplateError):
    """A template could not be lexed or parsed."""

    kind = "syntax"


class FilterError(TemplateError):
    """A template uses a filter that does not exist."""

    kind = "filter"


class UndefinedError(TemplateError):
    """The undefined value was used in a way that is not allowed."""

    kind = "undefined"


class TemplateNotFound(TemplateError):
    """An ``include`` or ``extends`` names a template that does not exist."""

    kind = "template"


class TemplateTypeError(TemplateError):
    """An operand or argument had the wrong kind."""

    kind = "type"
