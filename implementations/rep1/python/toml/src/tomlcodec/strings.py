"""Scanners for the four TOML string forms.

Each scanner takes the full text and the position of the opening delimiter and
returns ``(value, new_position)``; on malformed input it raises
:class:`~tomlcodec.errors.TomlDecodeError`.

Line endings are normalised (CRLF -> LF) by the caller before scanning, so
these scanners only ever see ``\\n``.
"""

from __future__ import annotations

import re

from .errors import TomlDecodeError

# Runs of characters that need no special handling.
_BASIC_RUN = re.compile(r'[^"\\\x00-\x08\x0a-\x1f\x7f]*')
_ML_BASIC_RUN = re.compile(r'[^"\\\x00-\x08\x0b-\x1f\x7f]*')
_LITERAL_RUN = re.compile(r"[^'\x00-\x08\x0a-\x1f\x7f]*")
_ML_LITERAL_RUN = re.compile(r"[^'\x00-\x08\x0b-\x1f\x7f]*")
_QUOTES = re.compile(r'"+')
_APOSTROPHES = re.compile(r"'+")
_LINE_CONTINUATION = re.compile(r"[ \t]*\n[ \t\n]*")
_HEX4 = re.compile(r"[0-9a-fA-F]{4}")
_HEX8 = re.compile(r"[0-9a-fA-F]{8}")

_SIMPLE_ESCAPES = {
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "f": "\f",
    "r": "\r",
    '"': '"',
    "\\": "\\",
}


def _escape(text: str, pos: int, out: list[str]) -> int:
    """Handle the escape whose backslash is at *pos*; return the next position."""
    try:
        c = text[pos + 1]
    except IndexError:
        raise TomlDecodeError("unterminated escape sequence", text, pos) from None
    simple = _SIMPLE_ESCAPES.get(c)
    if simple is not None:
        out.append(simple)
        return pos + 2
    if c == "u" or c == "U":
        width, rx = (4, _HEX4) if c == "u" else (8, _HEX8)
        if not rx.fullmatch(text, pos + 2, pos + 2 + width):
            raise TomlDecodeError("invalid unicode escape", text, pos)
        code = int(text[pos + 2 : pos + 2 + width], 16)
        if code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
            raise TomlDecodeError("escape is not a unicode scalar value", text, pos)
        out.append(chr(code))
        return pos + 2 + width
    raise TomlDecodeError("invalid escape sequence", text, pos)


def basic_string(text: str, pos: int) -> tuple[str, int]:
    """Scan ``"..."`` starting at the opening quote."""
    pos += 1
    out: list[str] = []
    while True:
        m = _BASIC_RUN.match(text, pos)
        end = m.end()
        if end > pos:
            out.append(text[pos:end])
        pos = end
        c = text[pos : pos + 1]
        if c == '"':
            return "".join(out), pos + 1
        if c == "\\":
            pos = _escape(text, pos, out)
        else:
            raise TomlDecodeError("invalid or unterminated string", text, pos)


def literal_string(text: str, pos: int) -> tuple[str, int]:
    """Scan ``'...'`` starting at the opening apostrophe."""
    start = pos + 1
    end = _LITERAL_RUN.match(text, start).end()
    if text[end : end + 1] != "'":
        raise TomlDecodeError("invalid or unterminated literal string", text, end)
    return text[start:end], end + 1


def multiline_basic_string(text: str, pos: int) -> tuple[str, int]:
    """Scan ``\"\"\"...\"\"\"`` starting at the first opening quote."""
    pos += 3
    if text.startswith("\n", pos):
        pos += 1
    out: list[str] = []
    while True:
        end = _ML_BASIC_RUN.match(text, pos).end()
        if end > pos:
            out.append(text[pos:end])
        pos = end
        c = text[pos : pos + 1]
        if c == '"':
            run = _QUOTES.match(text, pos).end() - pos
            if run < 3:
                out.append('"' * run)
                pos += run
            elif run <= 5:
                out.append('"' * (run - 3))
                return "".join(out), pos + run
            else:
                raise TomlDecodeError("too many quotes in multi-line string", text, pos)
        elif c == "\\":
            m = _LINE_CONTINUATION.match(text, pos + 1)
            if m:
                pos = m.end()
            else:
                pos = _escape(text, pos, out)
        else:
            raise TomlDecodeError("invalid or unterminated multi-line string", text, pos)


def multiline_literal_string(text: str, pos: int) -> tuple[str, int]:
    """Scan ``'''...'''`` starting at the first opening apostrophe."""
    pos += 3
    if text.startswith("\n", pos):
        pos += 1
    out: list[str] = []
    while True:
        end = _ML_LITERAL_RUN.match(text, pos).end()
        if end > pos:
            out.append(text[pos:end])
        pos = end
        if text[pos : pos + 1] != "'":
            raise TomlDecodeError("invalid or unterminated multi-line literal string", text, pos)
        run = _APOSTROPHES.match(text, pos).end() - pos
        if run < 3:
            out.append("'" * run)
            pos += run
        elif run <= 5:
            out.append("'" * (run - 3))
            return "".join(out), pos + run
        else:
            raise TomlDecodeError("too many apostrophes in multi-line literal string", text, pos)
