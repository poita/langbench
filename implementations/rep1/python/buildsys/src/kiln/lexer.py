"""KBL lexer: comment stripping, logical-line assembly and tokenisation.

All three stages share one *literal scanner* (:func:`skip_double`,
:func:`skip_single`) so they can never disagree about where a string literal
ends.  String literals are tokenised as opaque ``str`` tokens; their escapes and
interpolations are decoded later by the parser, so those errors are grammar
errors of the line holding the literal rather than lexical errors.

Token kinds are ``id``, ``int``, ``str`` and ``op`` (punctuation and
operators); a token is a ``(kind, text)`` pair.  The text of a ``str`` token is
the raw literal including its quotes.
"""

from __future__ import annotations

import re

from .errors import KilnError, SyntaxFail, parse_error

Token = tuple[str, bytes]
#: A logical line: its 1-based line number and its tokens.
LogicalLine = tuple[int, list[Token]]

RESERVED = frozenset(
    b"abort after cmd cost default depfile each elsewhen false in include let "
    b"otherwise out phony rule set step true use when".split()
)

_INTERESTING = re.compile(rb"[\"'#()\[\]]")
_TOKEN = re.compile(
    rb"[ \t]*(?:(?P<id>[A-Za-z_][A-Za-z0-9_]*)|(?P<int>[0-9]+)"
    rb"|(?P<op>\|>|\|\||&&|==|!=|<=|>=|\+\+|[()\[\]{},=<>~+\-*/%!])"
    rb"|(?P<q>[\"']))"
)
_TRAILING_WS = re.compile(rb"[ \t]+\Z")
_SPACE = b" \t"


def skip_single(buf: bytes, i: int) -> int:
    """Skip a single-quoted literal whose opening quote precedes *i*.

    Returns the index just past the closing quote.
    """
    n = len(buf)
    while True:
        j = buf.find(b"'", i)
        if j < 0:
            raise SyntaxFail("unterminated string literal")
        if j + 1 < n and buf[j + 1] == 0x27:
            i = j + 2
            continue
        return j + 1


def skip_double(buf: bytes, i: int) -> int:
    """Skip a double-quoted literal whose opening quote precedes *i*."""
    n = len(buf)
    while i < n:
        c = buf[i]
        if c == 0x5C:  # backslash consumes the next byte
            i += 2
        elif c == 0x7B:  # {
            if i + 1 < n and buf[i + 1] == 0x7B:
                i += 2
            else:
                i = skip_interpolation(buf, i + 1)
        elif c == 0x7D:  # }
            i += 2 if i + 1 < n and buf[i + 1] == 0x7D else 1
        elif c == 0x22:
            return i + 1
        else:
            i += 1
    raise SyntaxFail("unterminated string literal")


def skip_interpolation(buf: bytes, i: int) -> int:
    """Skip an interpolation region whose ``{`` precedes *i*.

    Returns the index just past the closing ``}``.
    """
    n = len(buf)
    depth = 1
    while i < n:
        c = buf[i]
        if c == 0x22:
            i = skip_double(buf, i + 1)
            continue
        if c == 0x27:
            i = skip_single(buf, i + 1)
            continue
        if c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise SyntaxFail("unterminated interpolation")


def scan_physical(line: bytes, depth: int) -> tuple[bytes, int]:
    """Strip the comment from one physical line and track bracket depth.

    Returns the line without comment or trailing blanks, and the new depth.
    """
    pos = 0
    n = len(line)
    search = _INTERESTING.search
    while True:
        m = search(line, pos)
        if m is None:
            break
        i = m.start()
        c = line[i]
        if c == 0x22:
            pos = skip_double(line, i + 1)
        elif c == 0x27:
            pos = skip_single(line, i + 1)
        elif c == 0x23:  # comment
            n = i
            break
        else:
            if c == 0x28 or c == 0x5B:
                depth += 1
            else:
                depth -= 1
                if depth < 0:
                    raise SyntaxFail("unbalanced bracket")
            pos = i + 1
    return line[:n].rstrip(_SPACE), depth


def tokenize(text: bytes) -> list[Token]:
    """Split one logical line (or interpolation body) into tokens."""
    tokens: list[Token] = []
    match = _TOKEN.match
    pos = 0
    n = len(text)
    while True:
        m = match(text, pos)
        if m is None:
            if text[pos:].strip(_SPACE):
                raise SyntaxFail("bad token")
            return tokens
        kind = m.lastgroup
        if kind == "q":
            start = m.end() - 1
            if text[start] == 0x22:
                end = skip_double(text, start + 1)
            else:
                end = skip_single(text, start + 1)
            tokens.append(("str", text[start:end]))
            pos = end
        else:
            tokens.append((kind, m.group(kind)))  # type: ignore[arg-type]
            pos = m.end()
        if pos >= n:
            return tokens


def logical_lines(path: bytes, source: bytes) -> list[LogicalLine]:
    """Lex *source* into logical lines.

    Raises ``E_PARSE`` for the first lexical error, attributed to the first
    physical line of the logical line being assembled.
    """
    result: list[LogicalLine] = []
    parts: list[bytes] = []
    start = 0
    depth = 0
    for lineno, raw in enumerate(source.split(b"\n"), 1):
        if not parts:
            start = lineno
        try:
            stripped, depth = scan_physical(raw, depth)
            parts.append(stripped)
            if depth == 0:
                text = parts[0] if len(parts) == 1 else b" ".join(parts)
                parts = []
                if text:
                    result.append((start, tokenize(text)))
        except SyntaxFail:
            raise parse_error(path, start) from None
    if parts and depth > 0:
        raise parse_error(path, start)
    return result


__all__ = [
    "RESERVED",
    "KilnError",
    "LogicalLine",
    "Token",
    "logical_lines",
    "scan_physical",
    "skip_double",
    "skip_interpolation",
    "skip_single",
    "tokenize",
]
