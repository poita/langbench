"""The public entry point: a set of named templates that can be rendered."""

from __future__ import annotations

from typing import Any, Mapping

from .errors import TemplateNotFoundError
from .interpreter import Interpreter
from .nodes import Template
from .parser import parse_template


class Environment:
    """A collection of named template sources.

    Templates are loaded lazily and at most once: the first time a template is
    needed (by :meth:`render`, or by an ``include``/``extends`` tag) it is
    lexed, parsed and filter-checked; the result is cached.

    >>> env = Environment({"main": "Hello {{ name }}!"})
    >>> env.render("main", {"name": "Ada"})
    'Hello Ada!'
    """

    def __init__(self, templates: Mapping[str, str]) -> None:
        self._sources = dict(templates)
        self._loaded: dict[str, Template] = {}
        self._interpreter = Interpreter(self.load)

    def load(self, name: str) -> Template:
        """Return the parsed template called ``name``.

        Raises :class:`~jtemplate.errors.TemplateNotFoundError` if there is no
        such template, and the syntax / filter errors if it is broken.
        """
        template = self._loaded.get(name)
        if template is None:
            try:
                source = self._sources[name]
            except KeyError:
                raise TemplateNotFoundError(f"template {name!r} not found") from None
            template = self._loaded[name] = parse_template(name, source)
        return template

    def render(self, name: str, context: Mapping[str, Any] | None = None) -> str:
        """Render template ``name`` with ``context`` (a mapping of variables).

        Context values are plain Python data: ``int``, ``float``, ``bool``,
        ``None``, ``str``, ``list`` and ``dict``.  Raises a
        :class:`~jtemplate.errors.TemplateError` subclass on failure; no
        partial output is returned.
        """
        template = self.load(name)
        return self._interpreter.render(template, dict(context or {}))


def render(templates: Mapping[str, str], context: Mapping[str, Any] | None = None, main: str | None = None) -> str:
    """Render ``main`` (default: the first template) from ``templates``."""
    if main is None:
        main = next(iter(templates))
    return Environment(templates).render(main, context)
