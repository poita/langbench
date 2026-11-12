"""jtemplate: a small Jinja2-style template engine.

Public API::

    from jtemplate import Environment, render

    env = Environment({"main": "Hello {{ name|upper }}!"})
    env.render("main", {"name": "Ada"})      # 'Hello ADA!'

    render({"main": "{{ 1 + 2 }}"}, {})      # '3'

Failures raise subclasses of :class:`TemplateError`, each with a ``kind``
(``syntax``, ``filter``, ``undefined``, ``template`` or ``type``).
"""

from .environment import Environment, render
from .errors import (
    TemplateError,
    TemplateNotFoundError,
    TemplateSyntaxError,
    TemplateTypeError,
    UndefinedValueError,
    UnknownFilterError,
)
from .inputformat import Document, parse_document

__all__ = [
    "Document",
    "Environment",
    "TemplateError",
    "TemplateNotFoundError",
    "TemplateSyntaxError",
    "TemplateTypeError",
    "UndefinedValueError",
    "UnknownFilterError",
    "parse_document",
    "render",
]
__version__ = "1.0.0"
