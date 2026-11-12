"""Public conversion functions."""

from __future__ import annotations

from .blocks import BlockParser
from .inlines import parse_inlines
from .nodes import Node
from .render import render_html


def parse(text: str) -> Node:
    """Parse Markdown ``text`` into a document tree.

    Block structure is built first; the content of every paragraph and
    heading is then parsed into inline nodes.  The returned node has type
    :data:`cmarkpy.nodes.DOCUMENT`.
    """
    parser = BlockParser()
    doc = parser.parse(text)
    for leaf in parser.leaves:
        content = "".join(leaf.lines)
        leaf.lines = []
        parse_inlines(leaf, content)
    return doc


def convert(text: str) -> str:
    """Convert Markdown ``text`` to HTML, exactly as ``cmark`` would."""
    return render_html(parse(text))
