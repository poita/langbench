"""A Jinja-style template engine (a subset of Jinja2's language).

Supported: ``{{ expr }}`` output, ``{# comments #}``, whitespace control,
``if``/``elif``/``else``, ``for``/``else`` with ``loop``, ``set``, ``macro``,
``include``, ``extends``/``block``/``super()``, the usual operators and
thirteen filters.

>>> env = Environment({"hello": "Hello {{ name|upper }}!"})
>>> env.render("hello", {"name": "world"})
'Hello WORLD!'
"""

from __future__ import annotations

import sys
from collections.abc import Mapping

from .errors import (
    FilterError, TemplateError, TemplateNotFound, TemplateSyntaxError,
    TemplateTypeError, UndefinedError,
)
from .interpreter import Interpreter
from .parser import Template, parse_template

__all__ = [
    "Environment", "Template", "parse_template",
    "TemplateError", "TemplateSyntaxError", "FilterError", "UndefinedError",
    "TemplateNotFound", "TemplateTypeError",
]

# Macro recursion and template nesting use several Python frames per level.
_RECURSION_LIMIT = 20000


class Environment:
    """A set of named templates that can render, include and extend each other.

    *sources* maps a template name to its source text.  Templates are parsed
    lazily, the first time they are needed, and at most once.  Values passed
    to :meth:`render` are plain Python values: ``str``, ``int``, ``float``,
    ``bool``, ``None``, ``list`` and ``dict``.  Dicts keep insertion order.
    """

    def __init__(self, sources: Mapping[str, str]) -> None:
        self._sources = sources
        self._templates: dict[str, Template] = {}
        self._interpreter = Interpreter(self.get_template)

    def get_template(self, name: str) -> Template:
        """Return the parsed template *name*, parsing it on first use.

        Raises :class:`TemplateNotFound` if there is no such template and
        :class:`TemplateSyntaxError` / :class:`FilterError` if it is invalid.
        """
        template = self._templates.get(name)
        if template is None:
            try:
                source = self._sources[name]
            except KeyError:
                raise TemplateNotFound(f"template {name!r} does not exist") from None
            template = self._templates[name] = parse_template(source)
        return template

    def render(self, name: str, context: Mapping[str, object]) -> str:
        """Render template *name* with *context* as its root scope.

        Raises a :class:`TemplateError` subclass on failure; no partial
        output is returned.
        """
        if sys.getrecursionlimit() < _RECURSION_LIMIT:
            sys.setrecursionlimit(_RECURSION_LIMIT)
        return self._interpreter.render(self.get_template(name), dict(context))
