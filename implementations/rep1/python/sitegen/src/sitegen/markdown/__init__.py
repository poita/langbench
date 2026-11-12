"""A CommonMark-subset to HTML converter.

The converter implements headings, thematic breaks, code blocks, block
quotes, lists, paragraphs and the usual inline constructs (emphasis, code
spans, links, images, autolinks, breaks, escapes and entities).  Raw HTML,
link reference definitions and extensions are not supported.

>>> to_html("Hello *world*")
'<p>Hello <em>world</em></p>\\n'
"""

from __future__ import annotations

import sys

from .blocks import parse_blocks
from .render import render_document

__all__ = ["to_html"]

# Blocks nest up to a few hundred levels; rendering recurses once per level.
_RECURSION_LIMIT = 5000


def to_html(text: str) -> str:
    """Convert the Markdown *text* to an HTML string.

    The result ends with a newline unless the document is empty, in which
    case it is the empty string.
    """
    if sys.getrecursionlimit() < _RECURSION_LIMIT:
        sys.setrecursionlimit(_RECURSION_LIMIT)
    return render_document(parse_blocks(text))
