"""Lexer: splits template source into text and tag items.

:func:`lex` returns a list of items, each either a :class:`TextItem` or a
:class:`TagItem` (an output tag ``{{ }}`` or a statement tag ``{% %}`` with its
tokenised content).  Comments are dropped.  Whitespace control (``-``) is
applied here, so the parser never sees it.

Tokens are ``(kind, value)`` tuples with kind one of ``"name"``, ``"kw"``,
``"int"``, ``"float"``, ``"str"`` and ``"op"``.
"""

from __future__ import annotations

import re
from typing import NamedTuple

from .errors import TemplateSyntaxError
from .values import WHITESPACE

Token = tuple[str, object]

KEYWORDS = frozenset({"and", "or", "not", "in", "is", "true", "false", "none"})

_OPENER = re.compile(r"\{[{%#]")
_TOKEN = re.compile(
    r"""
      (?P<name>[A-Za-z_][A-Za-z0-9_]*)
    | (?P<float>[0-9]+\.[0-9]+)
    | (?P<int>[0-9]+)
    | (?P<op>\*\*|//|==|!=|<=|>=|[~+\-*/%<>()\[\],|.=])
    """,
    re.VERBOSE,
)
_ESCAPES = {"\\": "\\", '"': '"', "'": "'", "n": "\n", "t": "\t"}


class TextItem(NamedTuple):
    text: str


class TagItem(NamedTuple):
    #: ``"{{"`` for output tags, ``"{%"`` for statement tags.
    opener: str
    tokens: list[Token]


Item = TextItem | TagItem


def lex(source: str) -> list[Item]:
    """Split ``source`` into text and tag items, applying whitespace control."""
    items: list[Item] = []
    pos = 0
    length = len(source)
    strip_next = False  # a preceding tag ended with "-"
    while True:
        match = _OPENER.search(source, pos)
        if match is None:
            text = source[pos:]
            if strip_next:
                text = text.lstrip(WHITESPACE)
            if text:
                items.append(TextItem(text))
            return items
        text = source[pos : match.start()]
        opener = match.group()
        cur = match.end()
        strip_before = cur < length and source[cur] == "-"
        if strip_before:
            cur += 1
        if strip_next:
            text = text.lstrip(WHITESPACE)
        if strip_before:
            text = text.rstrip(WHITESPACE)
        if text:
            items.append(TextItem(text))
        if opener == "{#":
            end = source.find("#}", cur)
            if end < 0:
                raise TemplateSyntaxError("unclosed comment")
            strip_next = end > cur and source[end - 1] == "-"
            pos = end + 2
        else:
            tokens, pos, strip_next = _lex_tag(source, cur, opener)
            items.append(TagItem(opener, tokens))


def _lex_tag(source: str, pos: int, opener: str) -> tuple[list[Token], int, bool]:
    """Tokenise a tag body starting at ``pos``.

    Returns the tokens, the position after the closer and whether the closer
    carried the ``-`` whitespace-control marker.
    """
    closer = "}}" if opener == "{{" else "%}"
    dash_closer = "-" + closer
    length = len(source)
    tokens: list[Token] = []
    while True:
        while pos < length and source[pos] in WHITESPACE:
            pos += 1
        if pos >= length:
            raise TemplateSyntaxError("unclosed tag")
        if source.startswith(closer, pos):
            return tokens, pos + 2, False
        if source.startswith(dash_closer, pos):
            return tokens, pos + 3, True
        char = source[pos]
        if char == '"' or char == "'":
            value, pos = _lex_string(source, pos)
            tokens.append(("str", value))
            continue
        match = _TOKEN.match(source, pos)
        if match is None:
            raise TemplateSyntaxError(f"unexpected character {char!r}")
        kind = match.lastgroup
        value = match.group()
        pos = match.end()
        if kind == "name":
            tokens.append(("kw" if value in KEYWORDS else "name", value))
        elif kind == "int":
            tokens.append(("int", int(value)))
        elif kind == "float":
            tokens.append(("float", float(value)))
        else:
            tokens.append(("op", value))


def _lex_string(source: str, pos: int) -> tuple[str, int]:
    quote = source[pos]
    pos += 1
    length = len(source)
    chunks: list[str] = []
    while pos < length:
        char = source[pos]
        if char == quote:
            return "".join(chunks), pos + 1
        if char == "\\":
            if pos + 1 >= length or source[pos + 1] not in _ESCAPES:
                raise TemplateSyntaxError("bad string escape")
            chunks.append(_ESCAPES[source[pos + 1]])
            pos += 2
        else:
            chunks.append(char)
            pos += 1
    raise TemplateSyntaxError("unterminated string")
