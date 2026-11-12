"""Parser for the combined JSON-context + named-templates input format.

::

    <JSON object, one or more lines>
    --
    === name
    <template body>
    === other
    <template body>
"""

from __future__ import annotations

import json
from typing import Any, NamedTuple


class Document(NamedTuple):
    """A parsed input document."""

    #: The JSON context (insertion ordered).
    context: dict[str, Any]
    #: Template name -> body, in input order; the first one is the main template.
    templates: dict[str, str]

    @property
    def main(self) -> str:
        """Name of the template to render (the first one)."""
        return next(iter(self.templates))


def parse_document(text: str) -> Document:
    """Split ``text`` into the JSON context and the named template bodies.

    Raises :class:`ValueError` if the separator line or a template is missing
    and :class:`json.JSONDecodeError` (a ``ValueError``) for invalid JSON.
    """
    lines = text.split("\n")
    try:
        separator = lines.index("--")
    except ValueError:
        raise ValueError("missing '--' separator line") from None
    context = json.loads("\n".join(lines[:separator]))
    if not isinstance(context, dict):
        raise ValueError("the JSON context must be an object")

    rest = lines[separator + 1 :]
    if text.endswith("\n"):
        rest.pop()  # one trailing LF of the input is not part of a body
    templates: dict[str, str] = {}
    name: str | None = None
    body: list[str] = []
    for line in rest:
        if line.startswith("=== "):
            if name is not None:
                templates[name] = "\n".join(body)
            name = line[4:]
            body = []
        elif name is not None:
            body.append(line)
    if name is not None:
        templates[name] = "\n".join(body)
    if not templates:
        raise ValueError("no templates in input")
    return Document(context, templates)
