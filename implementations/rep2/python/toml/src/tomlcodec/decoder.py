"""TOML 1.0.0 parser: text (or UTF-8 bytes) to a :class:`~tomlcodec.model.Table`.

A single-pass recursive-descent parser.  Every scan is bounded by the current
token or line, so parsing is linear in the document size.  Nesting depth is
limited only by the interpreter's recursion limit.
"""

from __future__ import annotations

import re

from . import scalars, tables
from .errors import TomlDecodeError
from .model import INLINE, STRING, Array, Node, Scalar, Table

_WS = re.compile(r"[ \t]*")
_COMMENT = re.compile(r"#[\t\x20-\x7e\x80-\U0010ffff]*")
# Whitespace, newlines and comments between array elements.
_ARRAY_GAP = re.compile(r"(?:[ \t\r\n]+|#[\t\x20-\x7e\x80-\U0010ffff]*)*")
_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")
_TOKEN = re.compile(r"[0-9A-Za-z_+.-]+")
_LONE_CR = re.compile(r"\r(?!\n)")
_HEX4 = re.compile(r"[0-9A-Fa-f]{4}")
_HEX8 = re.compile(r"[0-9A-Fa-f]{8}")
_QUOTES = re.compile(r'"+')
_APOSTROPHES = re.compile(r"'+")

_BASIC_CHUNK = re.compile(r'[\t\x20\x21\x23-\x5b\x5d-\x7e\x80-\U0010ffff]*')
_ML_BASIC_CHUNK = re.compile(r'[\t\n\r\x20\x21\x23-\x5b\x5d-\x7e\x80-\U0010ffff]*')
_LITERAL_CHUNK = re.compile(r"[\t\x20-\x26\x28-\x7e\x80-\U0010ffff]*")
_ML_LITERAL_CHUNK = re.compile(r"[\t\n\r\x20-\x26\x28-\x7e\x80-\U0010ffff]*")
_LINE_CONTINUATION = re.compile(r"[ \t]*\r?\n[ \t\r\n]*")

_SIMPLE_ESCAPES = {
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "f": "\f",
    "r": "\r",
    '"': '"',
    "\\": "\\",
}


class _Parser:
    def __init__(self, text: str):
        self.s = text
        self.n = len(text)

    # -- helpers -----------------------------------------------------------

    def _err(self, msg: str, i: int) -> TomlDecodeError:
        return TomlDecodeError(msg, i, self.s)

    def _ws(self, i: int) -> int:
        return _WS.match(self.s, i).end()  # type: ignore[union-attr]

    # -- document ----------------------------------------------------------

    def parse(self) -> Table:
        s, n = self.s, self.n
        if s.startswith("\ufeff"):
            raise self._err("byte-order mark is not allowed", 0)
        m = _LONE_CR.search(s)
        if m:
            raise self._err("carriage return without line feed", m.start())

        root = Table()
        current = root
        i = 0
        while i < n:
            i = self._ws(i)
            if i >= n:
                break
            c = s[i]
            if c == "\n":
                i += 1
                continue
            if c == "\r":
                i += 2
                continue
            if c == "#":
                i = self._end_of_line(i)
                continue
            try:
                if c == "[":
                    current, i = self._header(root, i)
                else:
                    i = self._key_value(current, i)
            except TomlDecodeError as exc:
                if exc.offset is None:
                    exc.locate(i, s)
                raise
            i = self._end_of_line(i)
        return root

    def _end_of_line(self, i: int) -> int:
        """Skip an optional comment, then require a newline or end of input."""
        s = self.s
        i = self._ws(i)
        if i < self.n and s[i] == "#":
            i = _COMMENT.match(s, i).end()  # type: ignore[union-attr]
        if i >= self.n:
            return i
        if s[i] == "\n":
            return i + 1
        if s.startswith("\r\n", i):
            return i + 2
        raise self._err("expected end of line", i)

    def _header(self, root: Table, i: int) -> tuple[Table, int]:
        s = self.s
        is_array = s.startswith("[[", i)
        keys, j = self._key(i + (2 if is_array else 1))
        close = "]]" if is_array else "]"
        if not s.startswith(close, j):
            raise self._err(f"expected {close!r}", j)
        if is_array:
            return tables.open_table_array(root, keys), j + 2
        return tables.open_table(root, keys), j + 1

    def _key_value(self, table: Table, i: int) -> int:
        keys, i = self._key(i)
        if self.s[i : i + 1] != "=":
            raise self._err("expected '='", i)
        i = self._ws(i + 1)
        value, i = self._value(i)
        tables.assign(table, keys, value)
        return i

    # -- keys --------------------------------------------------------------

    def _key(self, i: int) -> tuple[list[str], int]:
        s = self.s
        keys: list[str] = []
        while True:
            i = self._ws(i)
            c = s[i : i + 1]
            if c == '"':
                seg, i = self._basic_string(i)
            elif c == "'":
                seg, i = self._literal_string(i)
            else:
                m = _BARE_KEY.match(s, i)
                if not m:
                    raise self._err("expected a key", i)
                seg, i = m.group(), m.end()
            keys.append(seg)
            i = self._ws(i)
            if s.startswith(".", i):
                i += 1
                continue
            return keys, i

    # -- strings -----------------------------------------------------------

    def _escape(self, i: int, parts: list[str]) -> int:
        """Decode the escape whose backslash is at ``i``; return the next index."""
        s = self.s
        c = s[i + 1 : i + 2]
        simple = _SIMPLE_ESCAPES.get(c)
        if simple is not None:
            parts.append(simple)
            return i + 2
        if c == "u":
            m = _HEX4.match(s, i + 2)
            width = 4
        elif c == "U":
            m = _HEX8.match(s, i + 2)
            width = 8
        else:
            raise self._err("invalid escape sequence", i)
        if not m:
            raise self._err("invalid unicode escape", i)
        code = int(m.group(), 16)
        if code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
            raise self._err("escape is not a unicode scalar value", i)
        parts.append(chr(code))
        return i + 2 + width

    def _basic_string(self, i: int) -> tuple[str, int]:
        s = self.s
        i += 1
        parts: list[str] = []
        while True:
            end = _BASIC_CHUNK.match(s, i).end()  # type: ignore[union-attr]
            if end > i:
                parts.append(s[i:end])
                i = end
            c = s[i : i + 1]
            if c == '"':
                return "".join(parts), i + 1
            if c == "\\":
                i = self._escape(i, parts)
            else:
                raise self._err("invalid character in string", i)

    def _literal_string(self, i: int) -> tuple[str, int]:
        s = self.s
        start = i + 1
        end = _LITERAL_CHUNK.match(s, start).end()  # type: ignore[union-attr]
        if s[end : end + 1] != "'":
            raise self._err("invalid character in literal string", end)
        return s[start:end], end + 1

    def _skip_first_newline(self, i: int) -> int:
        s = self.s
        if s.startswith("\n", i):
            return i + 1
        if s.startswith("\r\n", i):
            return i + 2
        return i

    def _ml_basic_string(self, i: int) -> tuple[str, int]:
        s = self.s
        i = self._skip_first_newline(i + 3)
        parts: list[str] = []
        while True:
            end = _ML_BASIC_CHUNK.match(s, i).end()  # type: ignore[union-attr]
            if end > i:
                parts.append(s[i:end].replace("\r\n", "\n"))
                i = end
            c = s[i : i + 1]
            if c == '"':
                run = _QUOTES.match(s, i).end() - i  # type: ignore[union-attr]
                if run < 3:
                    parts.append('"' * run)
                    i += run
                elif run <= 5:
                    parts.append('"' * (run - 3))
                    return "".join(parts), i + run
                else:
                    raise self._err("too many quotes in multi-line string", i)
            elif c == "\\":
                m = _LINE_CONTINUATION.match(s, i + 1)
                i = m.end() if m else self._escape(i, parts)
            else:
                raise self._err("invalid or unterminated multi-line string", i)

    def _ml_literal_string(self, i: int) -> tuple[str, int]:
        s = self.s
        i = self._skip_first_newline(i + 3)
        parts: list[str] = []
        while True:
            end = _ML_LITERAL_CHUNK.match(s, i).end()  # type: ignore[union-attr]
            if end > i:
                parts.append(s[i:end].replace("\r\n", "\n"))
                i = end
            if s[i : i + 1] != "'":
                raise self._err("invalid or unterminated multi-line literal", i)
            run = _APOSTROPHES.match(s, i).end() - i  # type: ignore[union-attr]
            if run < 3:
                parts.append("'" * run)
                i += run
            elif run <= 5:
                parts.append("'" * (run - 3))
                return "".join(parts), i + run
            else:
                raise self._err("too many apostrophes in multi-line literal", i)

    # -- values ------------------------------------------------------------

    def _value(self, i: int) -> tuple[Node, int]:
        s = self.s
        c = s[i : i + 1]
        if c == '"':
            if s.startswith('"""', i):
                text, i = self._ml_basic_string(i)
            else:
                text, i = self._basic_string(i)
            return Scalar(STRING, text), i
        if c == "'":
            if s.startswith("'''", i):
                text, i = self._ml_literal_string(i)
            else:
                text, i = self._literal_string(i)
            return Scalar(STRING, text), i
        if c == "[":
            return self._array(i)
        if c == "{":
            return self._inline_table(i)
        if not c:
            raise self._err("expected a value", i)
        if "0" <= c <= "9":
            m = scalars.DATETIME_RE.match(s, i)
            if m:
                return scalars.datetime_from_match(m), m.end()
            m = scalars.TIME_RE.match(s, i)
            if m:
                return scalars.time_from_match(m), m.end()
        m = _TOKEN.match(s, i)
        if not m:
            raise self._err("expected a value", i)
        try:
            return scalars.parse_scalar_token(m.group()), m.end()
        except TomlDecodeError as exc:
            exc.locate(i, s)
            raise

    def _array(self, i: int) -> tuple[Array, int]:
        s = self.s
        elements: list[Node] = []
        i += 1
        while True:
            i = _ARRAY_GAP.match(s, i).end()  # type: ignore[union-attr]
            if s.startswith("]", i):
                return Array(elements), i + 1
            value, i = self._value(i)
            elements.append(value)
            i = _ARRAY_GAP.match(s, i).end()  # type: ignore[union-attr]
            c = s[i : i + 1]
            if c == ",":
                i += 1
            elif c != "]":
                raise self._err("expected ',' or ']' in array", i)

    def _inline_table(self, i: int) -> tuple[Table, int]:
        s = self.s
        table = Table()
        i = self._ws(i + 1)
        if s.startswith("}", i):
            table.state = INLINE
            return table, i + 1
        while True:
            keys, i = self._key(i)
            if s[i : i + 1] != "=":
                raise self._err("expected '='", i)
            i = self._ws(i + 1)
            value, i = self._value(i)
            try:
                tables.assign(table, keys, value)
            except TomlDecodeError as exc:
                exc.locate(i, s)
                raise
            i = self._ws(i)
            c = s[i : i + 1]
            if c == ",":
                i += 1
            elif c == "}":
                table.state = INLINE
                return table, i + 1
            else:
                raise self._err("expected ',' or '}' in inline table", i)


def loads(data: str | bytes | bytearray | memoryview) -> Table:
    """Parse a TOML 1.0.0 document into a :class:`~tomlcodec.model.Table`.

    ``data`` is either text or UTF-8 encoded bytes.  Raises
    :class:`~tomlcodec.errors.TomlDecodeError` if the document is not valid
    (including invalid UTF-8, or nesting deeper than the interpreter's
    recursion limit allows).
    """
    if not isinstance(data, str):
        try:
            data = bytes(data).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise TomlDecodeError(f"invalid UTF-8: {exc.reason}", exc.start) from None
    try:
        return _Parser(data).parse()
    except RecursionError:
        raise TomlDecodeError("document is nested too deeply") from None
