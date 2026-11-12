"""Splitting a template source into text and tags, and tokenizing tags."""

from __future__ import annotations

import re

from .errors import TemplateSyntaxError
from .values import WHITESPACE

# Token kinds.
NAME, INT, FLOAT, STRING, OP = "name", "int", "float", "string", "op"

#: A token is ``(kind, value)``.
Token = tuple[str, object]

#: A template item: ``("text", str)``, ``("var", tokens)`` or ``("stmt", tokens)``.
Item = tuple[str, object]

_TAG_OPEN = re.compile(r"\{[{%#]")
_TOKEN = re.compile(
    r"""
      (?P<ws>[ \t\n\r\x0c\x0b]+)
    | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
    | (?P<float>[0-9]+\.[0-9]+)
    | (?P<int>[0-9]+)
    | (?P<op>\*\*|//|==|!=|<=|>=|[~+\-*/%<>()\[\],|.=])
    """,
    re.VERBOSE,
)
_STRING_ESCAPES = {"\\": "\\", '"': '"', "'": "'", "n": "\n", "t": "\t"}


def split_template(source: str) -> list[Item]:
    """Split *source* into text and tag items, applying whitespace control."""
    items: list[Item] = []
    pos = 0
    size = len(source)
    strip_next = False
    while True:
        opener = _TAG_OPEN.search(source, pos)
        text = source[pos : opener.start() if opener else size]
        if strip_next:
            text = text.lstrip(WHITESPACE)
        if opener is None:
            if text:
                items.append(("text", text))
            return items
        kind = opener.group()[1]
        start = opener.end()
        if source.startswith("-", start):
            start += 1
            text = text.rstrip(WHITESPACE)
        if text:
            items.append(("text", text))
        if kind == "#":
            end = source.find("#}", start)
            if end == -1:
                raise TemplateSyntaxError("unterminated comment")
            strip_next = end > start and source[end - 1] == "-"
            pos = end + 2
        else:
            tokens, pos, strip_next = _tokenize_tag(source, start, kind)
            items.append(("var" if kind == "{" else "stmt", tokens))


def _tokenize_tag(source: str, pos: int, kind: str) -> tuple[list[Token], int, bool]:
    """Tokenize a tag's content starting at *pos*.

    Returns ``(tokens, position after the closer, whether the closer had -)``.
    """
    closer = "}}" if kind == "{" else "%}"
    tokens: list[Token] = []
    size = len(source)
    while True:
        if pos >= size:
            raise TemplateSyntaxError("unterminated tag")
        if source.startswith(closer, pos):
            return tokens, pos + 2, False
        if source[pos] == "-" and source.startswith(closer, pos + 1):
            return tokens, pos + 3, True
        ch = source[pos]
        if ch == '"' or ch == "'":
            value, pos = _read_string(source, pos)
            tokens.append((STRING, value))
            continue
        match = _TOKEN.match(source, pos)
        if match is None:
            raise TemplateSyntaxError(f"unexpected character {ch!r} in tag")
        group = match.lastgroup
        pos = match.end()
        if group == "ws":
            continue
        text = match.group()
        if group == "int":
            tokens.append((INT, int(text)))
        elif group == "float":
            tokens.append((FLOAT, float(text)))
        else:
            tokens.append((group, text))


def _read_string(source: str, pos: int) -> tuple[str, int]:
    quote = source[pos]
    pos += 1
    out: list[str] = []
    size = len(source)
    while pos < size:
        ch = source[pos]
        if ch == quote:
            return "".join(out), pos + 1
        if ch == "\\":
            esc = source[pos + 1 : pos + 2]
            if esc not in _STRING_ESCAPES or not esc:
                raise TemplateSyntaxError("invalid escape in string literal")
            out.append(_STRING_ESCAPES[esc])
            pos += 2
        else:
            end = pos + 1
            while end < size and source[end] != quote and source[end] != "\\":
                end += 1
            out.append(source[pos:end])
            pos = end
    raise TemplateSyntaxError("unterminated string literal")
