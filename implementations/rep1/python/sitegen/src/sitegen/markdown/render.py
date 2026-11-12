"""Rendering of the block and inline trees to HTML."""

from __future__ import annotations

from .blocks import (
    BLOCKQUOTE, CODE, DOCUMENT, HEADING, ITEM, LIST, PARAGRAPH, THEMATIC, Block,
)
from .inlines import (
    CODE as INLINE_CODE, EMPH, IMAGE, LINEBREAK, LINK, SOFTBREAK, STRONG, TEXT,
    Inline, parse_inlines,
)
from .text import WHITESPACE, escape_html, href

_CLOSE_TAGS = {EMPH: "</em>", STRONG: "</strong>", LINK: "</a>"}


class _Writer:
    """Output buffer that knows whether the output ends with a newline."""

    def __init__(self) -> None:
        self.parts: list[str] = []
        self.at_line_start = True

    def write(self, text: str) -> None:
        if text:
            self.parts.append(text)
            self.at_line_start = text[-1] == "\n"

    def cr(self) -> None:
        if not self.at_line_start:
            self.parts.append("\n")
            self.at_line_start = True


def render_document(root: Block) -> str:
    """Render a parsed block tree as HTML."""
    out = _Writer()
    _render_children(root, out)
    return "".join(out.parts)


def _render_children(block: Block, out: _Writer) -> None:
    for child in block.children:
        _render_block(child, out)


def _render_block(block: Block, out: _Writer) -> None:
    kind = block.kind
    if kind == PARAGRAPH:
        grandparent = block.parent.parent
        if grandparent is not None and grandparent.kind == LIST and grandparent.tight:
            _render_inlines(parse_inlines(_inline_source(block)), out)
        else:
            out.cr()
            out.write("<p>")
            _render_inlines(parse_inlines(_inline_source(block)), out)
            out.write("</p>\n")
    elif kind == ITEM:
        out.cr()
        out.write("<li>")
        _render_children(block, out)
        out.write("</li>\n")
    elif kind == LIST:
        out.cr()
        if not block.ordered:
            tag = "ul"
            out.write("<ul>\n")
        else:
            tag = "ol"
            out.write("<ol>\n" if block.start == 1 else f'<ol start="{block.start}">\n')
        _render_children(block, out)
        out.write(f"</{tag}>\n")
    elif kind == HEADING:
        out.cr()
        out.write(f"<h{block.level}>")
        _render_inlines(parse_inlines(_inline_source(block)), out)
        out.write(f"</h{block.level}>\n")
    elif kind == CODE:
        out.cr()
        info = block.info if block.fenced else ""
        if info:
            language = info.split(None, 1)[0]
            if not language.startswith("language-"):
                language = "language-" + language
            out.write(f'<pre><code class="{escape_html(language)}">')
        else:
            out.write("<pre><code>")
        out.write(escape_html(block.text))
        out.write("</code></pre>\n")
    elif kind == BLOCKQUOTE:
        out.cr()
        out.write("<blockquote>\n")
        _render_children(block, out)
        out.cr()
        out.write("</blockquote>\n")
    elif kind == THEMATIC:
        out.cr()
        out.write("<hr />\n")
    elif kind == DOCUMENT:
        _render_children(block, out)


def _inline_source(block: Block) -> str:
    return block.content.rstrip(WHITESPACE)


def _render_inlines(root: Inline, out: _Writer) -> None:
    """Render the children of *root* without recursion (nesting can be deep)."""
    write = out.write
    node = root.first
    while node is not None:
        kind = node.kind
        if kind == TEXT:
            write(escape_html(node.literal))
        elif kind == SOFTBREAK:
            write("\n")
        elif kind == LINEBREAK:
            write("<br />\n")
        elif kind == INLINE_CODE:
            write("<code>" + escape_html(node.literal) + "</code>")
        elif kind == IMAGE:
            title = "" if node.title is None else f' title="{escape_html(node.title)}"'
            write(f'<img src="{href(node.dest)}" alt="{_alt_text(node)}"{title} />')
        else:
            if kind == EMPH:
                write("<em>")
            elif kind == STRONG:
                write("<strong>")
            else:
                title = "" if node.title is None else f' title="{escape_html(node.title)}"'
                write(f'<a href="{href(node.dest)}"{title}>')
            if node.first is not None:
                node = node.first
                continue
            write(_CLOSE_TAGS[kind])
        # Move on to the next node, closing finished parents on the way up.
        while True:
            if node.next is not None:
                node = node.next
                break
            node = node.parent
            if node is root:
                node = None
                break
            write(_CLOSE_TAGS[node.kind])


def _alt_text(image: Inline) -> str:
    """The plain text of an image's descendants, HTML-escaped."""
    parts: list[str] = []
    node = image.first
    while node is not None:
        kind = node.kind
        if kind == TEXT or kind == INLINE_CODE:
            parts.append(escape_html(node.literal))
        elif kind == SOFTBREAK or kind == LINEBREAK:
            parts.append(" ")
        elif node.first is not None:
            node = node.first
            continue
        while True:
            if node.next is not None:
                node = node.next
                break
            node = node.parent
            if node is image:
                node = None
                break
    return "".join(parts)
