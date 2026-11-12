"""The KBL lexer: comment stripping, logical lines and tokens.

Stages 1 and 2 (comment stripping and logical-line assembly) are a single
pass over the physical lines, driven by the *literal scanner*
(:func:`skip_double` / :func:`skip_single`) that every stage shares.  Stage 3
tokenises each completed logical line.

Tokens are ``(kind, value)`` tuples.  ``kind`` is ``"ID"``, ``"INT"``,
``"STR"`` (value: the raw literal including its quotes) or, for punctuation
and operators, the symbol itself (``"("``, ``"|>"``, ...).
"""

from __future__ import annotations

import re

from .errors import KilnError, SyntaxFault

__all__ = [
    "Token", "RESERVED", "lex_file", "tokenize", "skip_double", "skip_single",
    "skip_region",
]

Token = tuple  # (kind: str, value: bytes | int)

RESERVED = frozenset(
    b"abort after cmd cost default depfile each elsewhen false in include let "
    b"otherwise out phony rule set step true use when".split()
)

_SPECIAL = re.compile(rb"""["'#()\[\]]""")
_DQ_STOP = re.compile(rb'[\\{}"]')
_REGION_STOP = re.compile(rb"""["'{}]""")
_TOKEN = re.compile(
    rb"""[ \t]*(?:([A-Za-z_][A-Za-z0-9_]*)|([0-9]+)"""
    rb"""|(\|>|\|\||&&|==|!=|<=|>=|\+\+|[()\[\]{},=<>~+\-*/%!])|(["']))"""
)


def skip_single(buf: bytes, i: int) -> int:
    """Skip a single-quoted literal whose content starts at ``buf[i]``.

    Returns the index just past the closing quote, or -1 if unterminated.
    """
    n = len(buf)
    while True:
        j = buf.find(b"'", i)
        if j < 0:
            return -1
        if j + 1 < n and buf[j + 1] == 0x27:
            i = j + 2
            continue
        return j + 1


def skip_region(buf: bytes, i: int) -> int:
    """Skip an interpolation region whose body starts at ``buf[i]``.

    Returns the index just past the closing ``}``, or -1 if unterminated.
    """
    depth = 1
    search = _REGION_STOP.search
    while True:
        m = search(buf, i)
        if m is None:
            return -1
        p = m.start()
        c = buf[p]
        if c == 0x22:
            i = skip_double(buf, p + 1)
            if i < 0:
                return -1
        elif c == 0x27:
            i = skip_single(buf, p + 1)
            if i < 0:
                return -1
        elif c == 0x7B:
            depth += 1
            i = p + 1
        else:
            depth -= 1
            i = p + 1
            if depth == 0:
                return i


def skip_double(buf: bytes, i: int) -> int:
    """Skip a double-quoted literal whose content starts at ``buf[i]``.

    Returns the index just past the closing quote, or -1 if unterminated.
    """
    n = len(buf)
    search = _DQ_STOP.search
    while True:
        m = search(buf, i)
        if m is None:
            return -1
        p = m.start()
        c = buf[p]
        if c == 0x22:
            return p + 1
        if c == 0x5C:
            i = p + 2
            if i > n:
                return -1
        elif c == 0x7B:
            if p + 1 < n and buf[p + 1] == 0x7B:
                i = p + 2
            else:
                i = skip_region(buf, p + 1)
                if i < 0:
                    return -1
        else:  # '}'
            i = p + 2 if p + 1 < n and buf[p + 1] == 0x7D else p + 1


def tokenize(text: bytes) -> list[Token]:
    """Split a logical line (or an interpolation body) into tokens."""
    tokens: list[Token] = []
    append = tokens.append
    match = _TOKEN.match
    pos = 0
    while True:
        m = match(text, pos)
        if m is None:
            if text[pos:].strip(b" \t") == b"":
                return tokens
            raise SyntaxFault("bad byte")
        ident, integer, punct, quote = m.groups()
        if ident is not None:
            append(("ID", ident))
        elif integer is not None:
            append(("INT", int(integer)))
        elif punct is not None:
            append((punct.decode("ascii"), punct))
        else:
            start = m.end() - 1
            if quote == b'"':
                end = skip_double(text, start + 1)
            else:
                end = skip_single(text, start + 1)
            if end < 0:
                raise SyntaxFault("unterminated literal")
            append(("STR", text[start:end]))
            pos = end
            continue
        pos = m.end()


def lex_file(path: bytes, source: bytes) -> list[tuple[int, list[Token]]]:
    """Lex a whole build file into ``(line_number, tokens)`` logical lines.

    Raises ``E_PARSE`` for the lexical error of the earliest logical line.
    """
    def fail(line: int) -> KilnError:
        return KilnError("E_PARSE", b"%b:%d" % (path, line))

    result: list[tuple[int, list[Token]]] = []
    depth = 0
    start = 0
    parts: list[bytes] = []
    special = _SPECIAL.search
    for lineno, line in enumerate(source.split(b"\n"), 1):
        if not parts:
            start = lineno
        i = 0
        while True:
            m = special(line, i)
            if m is None:
                break
            p = m.start()
            c = line[p]
            if c == 0x22:
                i = skip_double(line, p + 1)
                if i < 0:
                    raise fail(start)
            elif c == 0x27:
                i = skip_single(line, p + 1)
                if i < 0:
                    raise fail(start)
            elif c == 0x23:
                line = line[:p]
                break
            elif c == 0x28 or c == 0x5B:
                depth += 1
                i = p + 1
            else:
                depth -= 1
                if depth < 0:
                    raise fail(start)
                i = p + 1
        parts.append(line.rstrip(b" \t"))
        if depth == 0:
            text = parts[0] if len(parts) == 1 else b" ".join(parts)
            parts = []
            if text.strip(b" \t"):
                try:
                    result.append((start, tokenize(text)))
                except SyntaxFault:
                    raise fail(start) from None
    if depth > 0:
        raise fail(start)
    return result
