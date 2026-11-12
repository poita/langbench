"""The token stream of the command language (SPEC §6.1)."""

from __future__ import annotations

import re
from typing import NamedTuple

from .errors import TesseraError

WORD = "word"
INT = "int"
STRING = "string"
SYM = "sym"          # punctuation and comparison operators


class Token(NamedTuple):
    kind: str
    text: str        # STRING: the raw text between the quotes, escapes still unresolved


_TOKEN = re.compile(
    r"""[ \t]*(?:
        (?P<word>[A-Za-z_][A-Za-z0-9_]*)
      | (?P<int>-?[0-9]+)
      | "(?P<str>(?:[^"\\\x00-\x1f]+|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*)"
      | (?P<sym>==|!=|<=|>=|[<>{}\[\](),:.])
    )""",
    re.VERBOSE,
)
_INT_SHAPE = re.compile(r"(?:0|-?[1-9][0-9]*)\Z")
_TRAILING_WS = re.compile(r"[ \t]*\Z")


def tokenize(line: str) -> list[Token]:
    """Split one command line into tokens; raises ``syntax`` for any lexical error."""
    tokens: list[Token] = []
    pos = 0
    n = len(line)
    match = _TOKEN.match
    while True:
        m = match(line, pos)
        if m is None:
            if _TRAILING_WS.match(line, pos):
                return tokens
            raise TesseraError("syntax", "bad token")
        pos = m.end()
        kind = m.lastgroup
        if kind == "word":
            tokens.append(Token(WORD, m.group("word")))
        elif kind == "int":
            text = m.group("int")
            if not _INT_SHAPE.match(text):
                raise TesseraError("syntax", "bad integer")
            tokens.append(Token(INT, text))
        elif kind == "str":
            tokens.append(Token(STRING, m.group("str")))
        else:
            tokens.append(Token(SYM, m.group("sym")))
        if pos >= n:
            return tokens


_SIMPLE_ESCAPES = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f",
                   "n": "\n", "r": "\r", "t": "\t"}
_ESCAPE = re.compile(r"\\(?:u([0-9a-fA-F]{4})|(.))", re.DOTALL)
_LOW_SURROGATE = re.compile(r"\\u([dD][c-fC-F][0-9a-fA-F]{2})")


def resolve_string(raw: str) -> str:
    """Resolve the escapes of a lexically valid string token (SPEC §6.1).

    Raises ``bad-utf8`` for an unpaired UTF-16 surrogate escape.
    """
    if "\\" not in raw:
        return raw
    out: list[str] = []
    pos = 0
    n = len(raw)
    while pos < n:
        i = raw.find("\\", pos)
        if i < 0:
            out.append(raw[pos:])
            break
        out.append(raw[pos:i])
        m = _ESCAPE.match(raw, i)
        pos = m.end()
        if m.group(1) is None:
            out.append(_SIMPLE_ESCAPES[m.group(2)])
            continue
        unit = int(m.group(1), 16)
        if 0xD800 <= unit <= 0xDBFF:
            low = _LOW_SURROGATE.match(raw, pos)
            if low is None:
                raise TesseraError("bad-utf8", "unpaired high surrogate")
            pos = low.end()
            unit = 0x10000 + ((unit - 0xD800) << 10) + (int(low.group(1), 16) - 0xDC00)
        elif 0xDC00 <= unit <= 0xDFFF:
            raise TesseraError("bad-utf8", "unpaired low surrogate")
        out.append(chr(unit))
    return "".join(out)
