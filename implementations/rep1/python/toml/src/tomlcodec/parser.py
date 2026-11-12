"""The TOML 1.0.0 decoder: a single-pass recursive-descent parser.

The parser works on the decoded text with a moving position and a handful of
precompiled regular expressions, each of which only ever scans the current
token or line, so the whole parse is linear in the size of the document.
Table bookkeeping (explicit / implicit / dotted / inline) lives in
:class:`Parser`'s ``_assign``, ``_open_table`` and ``_open_array_table``.
"""

from __future__ import annotations

import re

from . import strings
from .datetimes import DATETIME_RE, canonical_datetime
from .errors import TomlDecodeError
from .model import (
    DOTTED,
    EXPLICIT,
    IMPLICIT,
    INLINE,
    ArrayOfTables,
    Node,
    Scalar,
    Table,
)
from .numeric import parse_float, parse_integer

_WS = re.compile(r"[ \t]*")
_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")
_COMMENT = re.compile(r"#[\t\x20-\x7e\x80-\U0010ffff]*")
_FILLER = re.compile(r"(?:[ \t\n]+|#[\t\x20-\x7e\x80-\U0010ffff]*)*")
_TOKEN = re.compile(r"[+\-0-9A-Za-z_.]+")
_DIGITS = frozenset("0123456789")


def loads(data: bytes | str) -> Table:
    """Parse a TOML 1.0.0 document and return its root :class:`Table`.

    *data* may be ``bytes`` (which must be valid UTF-8) or ``str``.
    Raises :class:`~tomlcodec.errors.TomlDecodeError` if the document is invalid.
    """
    if isinstance(data, (bytes, bytearray, memoryview)):
        try:
            text = bytes(data).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise TomlDecodeError(f"invalid UTF-8: {exc.reason}") from None
    else:
        text = data
    if text.startswith("\ufeff"):
        raise TomlDecodeError("byte-order mark is not allowed")
    # CRLF is a newline; a CR anywhere else is an error.
    if "\r" in text:
        text = text.replace("\r\n", "\n")
        pos = text.find("\r")
        if pos >= 0:
            raise TomlDecodeError("bare carriage return", text, pos)
    try:
        return Parser(text).parse()
    except RecursionError:
        raise TomlDecodeError("document is nested too deeply") from None


class Parser:
    """Parses one document. Use :func:`loads` rather than this class directly."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.n = len(text)
        self.pos = 0
        self.root = Table(EXPLICIT)

    # -- helpers ---------------------------------------------------------

    def _error(self, msg: str, pos: int | None = None) -> TomlDecodeError:
        return TomlDecodeError(msg, self.text, self.pos if pos is None else pos)

    def _skip_ws(self) -> None:
        self.pos = _WS.match(self.text, self.pos).end()

    def _finish_line(self) -> None:
        """After a statement: optional whitespace and comment, then newline or EOF."""
        text = self.text
        pos = _WS.match(text, self.pos).end()
        m = _COMMENT.match(text, pos)
        if m:
            pos = m.end()
        if pos < self.n:
            if text[pos] != "\n":
                raise self._error("unexpected characters after statement", pos)
            pos += 1
        self.pos = pos

    # -- document --------------------------------------------------------

    def parse(self) -> Table:
        text = self.text
        n = self.n
        current = self.root
        while self.pos < n:
            self._skip_ws()
            if self.pos >= n:
                break
            c = text[self.pos]
            if c == "\n":
                self.pos += 1
            elif c == "#":
                self._finish_line()
            elif c == "[":
                current = self._header()
                self._finish_line()
            else:
                self._key_value(current)
                self._finish_line()
        return self.root

    def _header(self) -> Table:
        text = self.text
        if text.startswith("[[", self.pos):
            self.pos += 2
            keys = self._key()
            if not text.startswith("]]", self.pos):
                raise self._error("expected ']]'")
            self.pos += 2
            return self._open_array_table(keys)
        self.pos += 1
        keys = self._key()
        if not text.startswith("]", self.pos):
            raise self._error("expected ']'")
        self.pos += 1
        return self._open_table(keys)

    # -- keys ------------------------------------------------------------

    def _key(self) -> list[str]:
        """Parse a (possibly dotted) key, with whitespace allowed around it."""
        text = self.text
        keys: list[str] = []
        while True:
            self._skip_ws()
            pos = self.pos
            c = text[pos : pos + 1]
            if c == '"':
                if text.startswith('"""', pos):
                    raise self._error("multi-line string used as key")
                key, self.pos = strings.basic_string(text, pos)
            elif c == "'":
                if text.startswith("'''", pos):
                    raise self._error("multi-line string used as key")
                key, self.pos = strings.literal_string(text, pos)
            else:
                m = _BARE_KEY.match(text, pos)
                if not m:
                    raise self._error("expected a key")
                key = m.group()
                self.pos = m.end()
            keys.append(key)
            self._skip_ws()
            if text.startswith(".", self.pos):
                self.pos += 1
            else:
                return keys

    def _key_value(self, table: Table) -> None:
        keys = self._key()
        if not self.text.startswith("=", self.pos):
            raise self._error("expected '='")
        self.pos += 1
        self._skip_ws()
        value = self._value()
        self._assign(table, keys, value)

    # -- table resolution --------------------------------------------------

    def _assign(self, table: Table, keys: list[str], value: Node) -> None:
        """Store ``keys = value`` in *table*, creating dotted tables on the way."""
        for k in keys[:-1]:
            child = table.get(k)
            if child is None:
                child = Table(DOTTED)
                table[k] = child
            elif type(child) is Table:
                state = child.state
                if state == EXPLICIT or state == INLINE:
                    raise self._error("dotted key reaches into an already defined table")
                child.state = DOTTED
            else:
                raise self._error("dotted key conflicts with an existing value")
            table = child
        last = keys[-1]
        if last in table:
            raise self._error("duplicate key")
        table[last] = value

    def _walk(self, keys: list[str]) -> Table:
        """Resolve all but the last segment of a header path."""
        table = self.root
        for k in keys[:-1]:
            child = table.get(k)
            if child is None:
                child = Table(IMPLICIT)
                table[k] = child
            elif type(child) is Table:
                if child.state == INLINE:
                    raise self._error("header reaches into an inline table")
            elif type(child) is ArrayOfTables:
                child = child[-1]
            else:
                raise self._error("header conflicts with an existing value")
            table = child
        return table

    def _open_table(self, keys: list[str]) -> Table:
        table = self._walk(keys)
        last = keys[-1]
        child = table.get(last)
        if child is None:
            child = Table(EXPLICIT)
            table[last] = child
            return child
        if type(child) is Table and child.state == IMPLICIT:
            child.state = EXPLICIT
            return child
        raise self._error("table is already defined")

    def _open_array_table(self, keys: list[str]) -> Table:
        table = self._walk(keys)
        last = keys[-1]
        child = table.get(last)
        element = Table(EXPLICIT)
        if child is None:
            table[last] = ArrayOfTables((element,))
        elif type(child) is ArrayOfTables:
            child.append(element)
        else:
            raise self._error("array of tables conflicts with an existing value")
        return element

    # -- values ----------------------------------------------------------

    def _value(self) -> Node:
        text = self.text
        pos = self.pos
        c = text[pos : pos + 1]
        if c == '"':
            if text.startswith('"""', pos):
                s, self.pos = strings.multiline_basic_string(text, pos)
            else:
                s, self.pos = strings.basic_string(text, pos)
            return Scalar("string", s)
        if c == "'":
            if text.startswith("'''", pos):
                s, self.pos = strings.multiline_literal_string(text, pos)
            else:
                s, self.pos = strings.literal_string(text, pos)
            return Scalar("string", s)
        if c == "[":
            return self._array()
        if c == "{":
            return self._inline_table()
        if c == "t" and text.startswith("true", pos):
            self.pos = pos + 4
            return Scalar("bool", "true")
        if c == "f" and text.startswith("false", pos):
            self.pos = pos + 5
            return Scalar("bool", "false")
        return self._number_or_date()

    def _number_or_date(self) -> Scalar:
        text = self.text
        pos = self.pos
        if text[pos : pos + 1] in _DIGITS:
            m = DATETIME_RE.match(text, pos)
            if m:
                result = canonical_datetime(m)
                if result is None:
                    raise self._error("invalid date or time")
                self.pos = m.end()
                return Scalar(*result)
        m = _TOKEN.match(text, pos)
        if not m:
            raise self._error("expected a value")
        token = m.group()
        canonical = parse_integer(token)
        if canonical is not None:
            self.pos = m.end()
            return Scalar("integer", canonical)
        canonical = parse_float(token)
        if canonical is not None:
            self.pos = m.end()
            return Scalar("float", canonical)
        raise self._error("invalid value")

    def _array(self) -> list:
        text = self.text
        self.pos += 1
        items: list[Node] = []
        while True:
            self.pos = _FILLER.match(text, self.pos).end()
            if text.startswith("]", self.pos):
                self.pos += 1
                return items
            items.append(self._value())
            self.pos = _FILLER.match(text, self.pos).end()
            if text.startswith(",", self.pos):
                self.pos += 1
            elif text.startswith("]", self.pos):
                self.pos += 1
                return items
            else:
                raise self._error("expected ',' or ']' in array")

    def _inline_table(self) -> Table:
        text = self.text
        table = Table(INLINE)
        self.pos += 1
        self._skip_ws()
        if text.startswith("}", self.pos):
            self.pos += 1
            return table
        while True:
            self._key_value(table)
            self._skip_ws()
            if text.startswith(",", self.pos):
                self.pos += 1
            elif text.startswith("}", self.pos):
                self.pos += 1
                return table
            else:
                raise self._error("expected ',' or '}' in inline table")
