"""Reader for the small TOML subset used by ``site.toml`` and front matter.

The subset has comments, blank lines and ``key = value`` assignments whose
values are basic strings, integers, booleans or one-line arrays of strings.
There are no tables, dotted keys or multi-line values.

>>> loads('title = "Hi"  # comment\\nn = 3\\ntags = ["a", "b",]')
{'title': 'Hi', 'n': 3, 'tags': ['a', 'b']}
"""

from __future__ import annotations

import re

from .errors import TomlError

TomlValue = str | int | bool | list[str]

_KEY = re.compile(r"[ \t]*([A-Za-z0-9_-]+)[ \t]*=[ \t]*")
_INT = re.compile(r"-?(?:0|[1-9][0-9]*)")
_HEX4 = re.compile(r"[0-9A-Fa-f]{4}")
_SIMPLE_ESCAPES = {'"': '"', "\\": "\\", "n": "\n", "t": "\t", "r": "\r"}


def loads(text: str) -> dict[str, TomlValue]:
    """Parse *text* and return its assignments as an insertion-ordered dict.

    Raises :class:`TomlError` if a line is not valid in the subset or a key
    is assigned twice.
    """
    result: dict[str, TomlValue] = {}
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.lstrip(" \t")
        if not stripped or stripped[0] == "#":
            continue
        try:
            key, value = _parse_assignment(line)
        except TomlError as exc:
            raise TomlError(f"line {number}: {exc}") from None
        if key in result:
            raise TomlError(f"line {number}: duplicate key {key!r}")
        result[key] = value
    return result


def _parse_assignment(line: str) -> tuple[str, TomlValue]:
    match = _KEY.match(line)
    if match is None:
        raise TomlError("expected `key = value`")
    value, pos = _parse_value(line, match.end())
    rest = line[pos:].lstrip(" \t")
    if rest and rest[0] != "#":
        raise TomlError(f"unexpected text after value: {rest!r}")
    return match.group(1), value


def _parse_value(line: str, pos: int) -> tuple[TomlValue, int]:
    ch = line[pos : pos + 1]
    if ch == '"':
        return _parse_string(line, pos)
    if ch == "[":
        return _parse_array(line, pos)
    if line.startswith("true", pos):
        return True, pos + 4
    if line.startswith("false", pos):
        return False, pos + 5
    match = _INT.match(line, pos)
    if match is not None:
        return int(match.group()), match.end()
    raise TomlError("invalid value")


def _parse_string(line: str, pos: int) -> tuple[str, int]:
    """Parse the basic string starting at the opening quote at *pos*."""
    pos += 1
    out: list[str] = []
    n = len(line)
    while pos < n:
        ch = line[pos]
        if ch == '"':
            return "".join(out), pos + 1
        if ch != "\\":
            # Copy the run of ordinary characters in one go.
            end = pos + 1
            while end < n and line[end] != '"' and line[end] != "\\":
                end += 1
            out.append(line[pos:end])
            pos = end
            continue
        esc = line[pos + 1 : pos + 2]
        if esc in _SIMPLE_ESCAPES:
            out.append(_SIMPLE_ESCAPES[esc])
            pos += 2
        elif esc == "u" and _HEX4.fullmatch(line, pos + 2, pos + 6):
            out.append(chr(int(line[pos + 2 : pos + 6], 16)))
            pos += 6
        else:
            raise TomlError("invalid escape sequence")
    raise TomlError("unterminated string")


def _parse_array(line: str, pos: int) -> tuple[list[str], int]:
    pos = _skip_blanks(line, pos + 1)
    items: list[str] = []
    while True:
        if line[pos : pos + 1] == "]":
            return items, pos + 1
        if line[pos : pos + 1] != '"':
            raise TomlError("invalid array element")
        item, pos = _parse_string(line, pos)
        items.append(item)
        pos = _skip_blanks(line, pos)
        if line[pos : pos + 1] == ",":
            pos = _skip_blanks(line, pos + 1)
        elif line[pos : pos + 1] != "]":
            raise TomlError("expected `,` or `]` in array")


def _skip_blanks(line: str, pos: int) -> int:
    n = len(line)
    while pos < n and line[pos] in " \t":
        pos += 1
    return pos
