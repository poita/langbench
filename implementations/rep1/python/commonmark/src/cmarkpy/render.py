"""Render a document tree to HTML (one iterative walk over the tree)."""

from __future__ import annotations

import re

from .escaping import escape_html, href
from .nodes import (
    BLOCK_QUOTE,
    CODE,
    CODE_BLOCK,
    DOCUMENT,
    EMPH,
    HEADING,
    IMAGE,
    ITEM,
    LINEBREAK,
    LINK,
    LIST,
    PARAGRAPH,
    SOFTBREAK,
    STRONG,
    TEXT,
    THEMATIC_BREAK,
    Node,
)

_WS_SPLIT = re.compile(r"[ \t\n\x0b\x0c\r]")
_LEAF_TYPES = frozenset({TEXT, SOFTBREAK, LINEBREAK, CODE, CODE_BLOCK, THEMATIC_BREAK})


def render_html(root: Node) -> str:
    """Render the tree rooted at ``root`` (normally a document) as HTML."""
    out: list[str] = []
    append = out.append

    def cr() -> None:
        if out and not out[-1].endswith("\n"):
            append("\n")

    stack: list[tuple[Node, bool]] = [(root, True)]
    pop = stack.pop
    push = stack.append
    alt_depth = 0  # > 0 while inside an image's alt text
    while stack:
        node, entering = pop()
        t = node.type
        if entering:
            if alt_depth:
                if t == TEXT or t == CODE:
                    if node.literal:
                        append(escape_html(node.literal))
                elif t == SOFTBREAK or t == LINEBREAK:
                    append(" ")
                elif t == IMAGE:
                    alt_depth += 1
            elif t == TEXT:
                if node.literal:
                    append(escape_html(node.literal))
            elif t == SOFTBREAK:
                append("\n")
            elif t == LINEBREAK:
                append("<br />\n")
            elif t == CODE:
                append("<code>" + escape_html(node.literal) + "</code>")
            elif t == EMPH:
                append("<em>")
            elif t == STRONG:
                append("<strong>")
            elif t == LINK:
                tag = '<a href="' + href(node.dest) + '"'
                if node.title is not None:
                    tag += ' title="' + escape_html(node.title) + '"'
                append(tag + ">")
            elif t == IMAGE:
                append('<img src="' + href(node.dest) + '" alt="')
                alt_depth = 1
            elif t == PARAGRAPH:
                parent = node.parent
                if not (parent.type == ITEM and parent.parent.tight):
                    cr()
                    append("<p>")
            elif t == ITEM:
                cr()
                append("<li>")
            elif t == LIST:
                cr()
                if not node.ordered:
                    append("<ul>\n")
                elif node.start == 1:
                    append("<ol>\n")
                else:
                    append(f'<ol start="{node.start}">\n')
            elif t == BLOCK_QUOTE:
                cr()
                append("<blockquote>\n")
            elif t == HEADING:
                cr()
                append(f"<h{node.level}>")
            elif t == CODE_BLOCK:
                cr()
                info = node.info
                if info:
                    word = _WS_SPLIT.split(info, 1)[0]
                    if word.startswith("language-"):
                        cls = word
                    else:
                        cls = "language-" + word
                    append(f'<pre><code class="{escape_html(cls)}">')
                else:
                    append("<pre><code>")
                append(escape_html(node.literal))
                append("</code></pre>\n")
            elif t == THEMATIC_BREAK:
                cr()
                append("<hr />\n")
            # DOCUMENT: nothing.
            if t not in _LEAF_TYPES:
                push((node, False))
                child = node.last_child
                while child is not None:
                    push((child, True))
                    child = child.prev
        else:
            if alt_depth:
                if t == IMAGE:
                    alt_depth -= 1
                    if not alt_depth:
                        tail = '"'
                        if node.title is not None:
                            tail += ' title="' + escape_html(node.title) + '"'
                        append(tail + " />")
            elif t == EMPH:
                append("</em>")
            elif t == STRONG:
                append("</strong>")
            elif t == LINK:
                append("</a>")
            elif t == PARAGRAPH:
                parent = node.parent
                if not (parent.type == ITEM and parent.parent.tight):
                    append("</p>\n")
            elif t == ITEM:
                append("</li>\n")
            elif t == LIST:
                append("</ul>\n" if not node.ordered else "</ol>\n")
            elif t == BLOCK_QUOTE:
                cr()
                append("</blockquote>\n")
            elif t == HEADING:
                append(f"</h{node.level}>\n")
    return "".join(out)
