"""Canonical TOML writer: a :class:`~tomlcodec.model.Table` to TOML text.

The output format is fully determined by the tree (specification part 2):
keys are sorted by code point, plain pairs come before sub-table headers,
every table gets a header, and arrays are written inline unless they are
non-empty arrays of tables.
"""

from __future__ import annotations

import re

from .model import Array, Node, Scalar, Table

_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")
_NEEDS_ESCAPE = re.compile(r'["\\\x00-\x1f\x7f]')
_ESCAPES = {chr(i): "\\u%04x" % i for i in range(0x20)}
_ESCAPES["\x7f"] = "\\u007f"
_ESCAPES.update(
    {"\b": "\\b", "\t": "\\t", "\n": "\\n", "\f": "\\f", "\r": "\\r", '"': '\\"', "\\": "\\\\"}
)


def quote_string(text: str) -> str:
    """Render ``text`` as a TOML basic string."""
    if _NEEDS_ESCAPE.search(text) is None:
        return f'"{text}"'
    return '"' + _NEEDS_ESCAPE.sub(lambda m: _ESCAPES[m.group()], text) + '"'


def format_key(key: str) -> str:
    """Render one key: bare when possible, otherwise a basic string."""
    if _BARE_KEY.fullmatch(key):
        return key
    return quote_string(key)


def _is_table_array(node: Node) -> bool:
    return (
        isinstance(node, Array)
        and len(node.elements) > 0
        and all(isinstance(e, Table) for e in node.elements)
    )


def _inline(node: Node) -> str:
    if isinstance(node, Scalar):
        return quote_string(node.text) if node.type == "string" else node.text
    if isinstance(node, Array):
        return "[" + ", ".join(_inline(e) for e in node.elements) + "]"
    entries = node.entries
    return (
        "{"
        + ", ".join(f"{format_key(k)} = {_inline(entries[k])}" for k in sorted(entries))
        + "}"
    )


def _render(table: Table, path: str, out: list[str]) -> None:
    entries = table.entries
    keys = sorted(entries)
    deferred: list[str] = []
    for key in keys:
        node = entries[key]
        if isinstance(node, Table) or _is_table_array(node):
            deferred.append(key)
        else:
            out.append(f"{format_key(key)} = {_inline(node)}")
    for key in deferred:
        node = entries[key]
        child_path = f"{path}.{format_key(key)}" if path else format_key(key)
        if isinstance(node, Table):
            if out:
                out.append("")
            out.append(f"[{child_path}]")
            _render(node, child_path, out)
        else:
            for element in node.elements:
                if out:
                    out.append("")
                out.append(f"[[{child_path}]]")
                _render(element, child_path, out)


def dumps(table: Table) -> str:
    """Serialise ``table`` as canonical TOML ending in a single newline."""
    out: list[str] = []
    _render(table, "", out)
    return "\n".join(out) + "\n"
