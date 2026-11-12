"""Lexer for Vellum (SPEC section 3).

``tokenize(text)`` turns one module body into a list of :class:`Token`
ending with an ``eof`` token.  Positions are module-local ``(line, col)``.
"""

from __future__ import annotations

import re

from .diagnostics import CompileError
from .source import KEYWORDS

INT_MAX = 9223372036854775807


class Token:
    """A lexical token.  ``kind`` is the token text for keywords and punctuation."""

    __slots__ = ("kind", "val", "line", "col")

    def __init__(self, kind: str, val, line: int, col: int):
        self.kind = kind
        self.val = val
        self.line = line
        self.col = col

    @property
    def pos(self) -> tuple[int, int]:
        return (self.line, self.col)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Token({self.kind!r}, {self.val!r}, {self.line}:{self.col})"


_TOKEN_RE = re.compile(
    r"""
    (?P<ws>[ \t\r\n]+)
  | (?P<lc>//[^\n]*)
  | (?P<bc>/\*)
  | (?P<id>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<num>[0-9])
  | (?P<str>")
  | (?P<chr>')
  | (?P<punct>\#\[|::|\.\.|->|==|!=|<=|>=|&&|\|\||<<|>>|\+\+|[()\[\]{},;:.|+\-*/%!~&^<>=])
    """,
    re.X,
)
_HEX = re.compile(r"0x[0-9a-fA-F][0-9a-fA-F_]*")
_BIN = re.compile(r"0b[01][01_]*")
_DEC = re.compile(r"[0-9][0-9_]*(\.[0-9][0-9_]*)?([eE][+-]?[0-9][0-9_]*)?")
_PLAIN_STR = re.compile(r'[^"\\\n\r]*')
_HEX_DIGITS = frozenset("0123456789abcdefABCDEF")

_SIMPLE_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "0": "\0",
    "\\": "\\",
    "'": "'",
    '"': '"',
}


def _escape(text: str, i: int, line: int, col: int) -> tuple[str, int]:
    """Decode the escape whose backslash is at ``text[i]``; return (char, next index)."""
    bad = CompileError("bad-escape", line, col)
    j = i + 1
    if j >= len(text):
        raise bad
    c = text[j]
    if c in _SIMPLE_ESCAPES:
        return _SIMPLE_ESCAPES[c], j + 1
    if c == "u":
        j += 1
        if j >= len(text) or text[j] != "{":
            raise bad
        j += 1
        k = j
        while k < len(text) and text[k] in _HEX_DIGITS:
            k += 1
        ndig = k - j
        if ndig < 1 or ndig > 6 or k >= len(text) or text[k] != "}":
            raise bad
        v = int(text[j:k], 16)
        if v > 0x10FFFF or 0xD800 <= v <= 0xDFFF:
            raise bad
        return chr(v), k + 1
    raise bad


def tokenize(text: str) -> list[Token]:
    """Lex one module body.  Raises :class:`CompileError` on the first bad token."""
    tokens: list[Token] = []
    add = tokens.append
    match = _TOKEN_RE.match
    n = len(text)
    pos = 0
    line = 1
    line_start = 0
    while pos < n:
        m = match(text, pos)
        if m is None:
            raise CompileError("bad-token", line, pos - line_start + 1)
        kind = m.lastgroup
        end = m.end()
        col = pos - line_start + 1
        if kind == "ws":
            nl = text.count("\n", pos, end)
            if nl:
                line += nl
                line_start = text.rindex("\n", pos, end) + 1
        elif kind == "lc":
            pass
        elif kind == "punct":
            s = m.group()
            add(Token(s, None, line, col))
        elif kind == "id":
            s = m.group()
            if s in KEYWORDS:
                add(Token(s, None, line, col))
            elif s == "_":
                add(Token("_", None, line, col))
            elif len(s) > 200:
                raise CompileError("bad-token", line, col)
            else:
                add(Token("ident", s, line, col))
        elif kind == "bc":
            depth = 1
            j = pos + 2
            while depth:
                a = text.find("/*", j)
                b = text.find("*/", j)
                if b < 0:
                    raise CompileError("unterminated", line, col)
                if 0 <= a < b:
                    depth += 1
                    j = a + 2
                else:
                    depth -= 1
                    j = b + 2
            end = j
            nl = text.count("\n", pos, end)
            if nl:
                line += nl
                line_start = text.rindex("\n", pos, end) + 1
        elif kind == "num":
            tok, end = _number(text, pos, line, col)
            add(tok)
        elif kind == "str":
            j = pos + 1
            parts = []
            while True:
                pm = _PLAIN_STR.match(text, j)
                parts.append(pm.group())
                j = pm.end()
                if j >= n or text[j] in "\n\r":
                    raise CompileError("unterminated", line, col)
                c = text[j]
                if c == '"':
                    j += 1
                    break
                ch, j2 = _escape(text, j, line, j - line_start + 1)
                parts.append(ch)
                j = j2
            end = j
            add(Token("str", "".join(parts), line, col))
        else:  # chr
            j = pos + 1
            if j >= n or text[j] in "'\n\r":
                raise CompileError("unterminated", line, col)
            if text[j] == "\\":
                ch, j = _escape(text, j, line, j - line_start + 1)
            else:
                ch = text[j]
                j += 1
            if j >= n or text[j] != "'":
                raise CompileError("unterminated", line, col)
            end = j + 1
            add(Token("char", ch, line, col))
        pos = end
    return tokens


def _number(text: str, pos: int, line: int, col: int) -> tuple[Token, int]:
    if text.startswith("0x", pos) or text.startswith("0b", pos):
        rx = _HEX if text[pos + 1] == "x" else _BIN
        m = rx.match(text, pos)
        if m is None:
            raise CompileError("bad-token", line, col)
        digits = m.group()[2:].replace("_", "")
        base = 16 if text[pos + 1] == "x" else 2
        v = int(digits, base) if len(digits.lstrip("0")) <= 70 else INT_MAX + 1
        if v > INT_MAX:
            raise CompileError("int-range", line, col)
        return Token("int", v, line, col), m.end()
    m = _DEC.match(text, pos)
    s = m.group().replace("_", "")
    if m.group(1) is None and m.group(2) is None:
        v = int(s) if len(s.lstrip("0")) <= 20 else INT_MAX + 1
        if v > INT_MAX:
            raise CompileError("int-range", line, col)
        return Token("int", v, line, col), m.end()
    return Token("float", float(s), line, col), m.end()
