"""Canonical TOML output.

The format is defined so that equal trees always give identical bytes:
non-table values first, in key order, then sub-tables and arrays of tables
in key order, each introduced by a header and a preceding blank line.
"""

from __future__ import annotations

import re

from .model import Scalar

_BARE = re.compile(r"[A-Za-z0-9_-]+")

_ESCAPES = {i: "\\u%04x" % i for i in range(0x20)}
_ESCAPES.update(
    {
        0x7F: "\\u007f",
        0x22: '\\"',
        0x5C: "\\\\",
        0x08: "\\b",
        0x09: "\\t",
        0x0A: "\\n",
        0x0C: "\\f",
        0x0D: "\\r",
    }
)


def quote_string(s: str) -> str:
    """Render *s* as a TOML basic string."""
    return '"' + s.translate(_ESCAPES) + '"'


def render_key(key: str) -> str:
    """Render one key segment: bare when possible, else a basic string."""
    if _BARE.fullmatch(key):
        return key
    return quote_string(key)


def _is_array_of_tables(value: object) -> bool:
    return isinstance(value, list) and len(value) > 0 and all(isinstance(e, dict) for e in value)


def _inline(value: object) -> str:
    if isinstance(value, Scalar):
        if value.type == "string":
            return quote_string(value.text)
        return value.text
    if isinstance(value, dict):
        items = [f"{render_key(k)} = {_inline(value[k])}" for k in sorted(value)]
        return "{" + ", ".join(items) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(_inline(e) for e in value) + "]"
    raise TypeError(f"cannot serialise {type(value).__name__}")


def _render_table(table: dict, path: list[str], lines: list[str]) -> None:
    keys = sorted(table)
    nested = []
    for key in keys:
        value = table[key]
        if isinstance(value, dict) or _is_array_of_tables(value):
            nested.append(key)
        else:
            lines.append(f"{render_key(key)} = {_inline(value)}")
    for key in nested:
        value = table[key]
        sub_path = path + [render_key(key)]
        dotted = ".".join(sub_path)
        if isinstance(value, dict):
            if lines:
                lines.append("")
            lines.append(f"[{dotted}]")
            _render_table(value, sub_path, lines)
        else:
            for element in value:
                if lines:
                    lines.append("")
                lines.append(f"[[{dotted}]]")
                _render_table(element, sub_path, lines)


def dumps(tree: dict) -> str:
    """Serialise *tree* as a canonical TOML document ending in a newline."""
    lines: list[str] = []
    _render_table(tree, [], lines)
    return "\n".join(lines) + "\n"
