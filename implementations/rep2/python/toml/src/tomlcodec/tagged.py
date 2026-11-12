"""Tagged JSON: the interchange format of the ``toml-test`` suite.

A table is a JSON object, an array a JSON array, and a scalar an object
``{"type": ..., "value": ...}`` whose members are both strings.  This module
writes the compact, key-sorted form and reads any well-formed equivalent.
"""

from __future__ import annotations

import json
import re

from .errors import TaggedJsonError
from .model import SCALAR_TYPES, Array, Node, Scalar, Table

_NEEDS_ESCAPE = re.compile(r'["\\\x00-\x1f]')
_ESCAPES = {i: "\\u%04x" % i for i in range(0x20)}
_ESCAPES.update(
    {0x08: "\\b", 0x09: "\\t", 0x0A: "\\n", 0x0C: "\\f", 0x0D: "\\r", 0x22: '\\"', 0x5C: "\\\\"}
)
_ESCAPE_TABLE = {chr(k): v for k, v in _ESCAPES.items()}


def _quote(text: str) -> str:
    if _NEEDS_ESCAPE.search(text) is None:
        return f'"{text}"'
    return '"' + _NEEDS_ESCAPE.sub(lambda m: _ESCAPE_TABLE[m.group()], text) + '"'


def _write(node: Node, out: list[str]) -> None:
    if isinstance(node, Scalar):
        out.append(f'{{"type":"{node.type}","value":{_quote(node.text)}}}')
    elif isinstance(node, Table):
        entries = node.entries
        out.append("{")
        first = True
        for key in sorted(entries):
            if first:
                first = False
            else:
                out.append(",")
            out.append(_quote(key))
            out.append(":")
            _write(entries[key], out)
        out.append("}")
    else:
        out.append("[")
        first = True
        for element in node.elements:
            if first:
                first = False
            else:
                out.append(",")
            _write(element, out)
        out.append("]")


def dumps(node: Node) -> str:
    """Serialise a tree as compact, key-sorted tagged JSON (no newline)."""
    out: list[str] = []
    _write(node, out)
    return "".join(out)


def _is_scalar_object(obj: dict) -> bool:
    return (
        len(obj) == 2
        and isinstance(obj.get("type"), str)
        and isinstance(obj.get("value"), str)
        and obj["type"] in SCALAR_TYPES
    )


def _convert(obj: object) -> Node:
    if isinstance(obj, dict):
        if _is_scalar_object(obj):
            return Scalar(obj["type"], obj["value"])
        return Table({k: _convert(v) for k, v in obj.items()})
    if isinstance(obj, list):
        return Array([_convert(v) for v in obj])
    raise TaggedJsonError(f"unexpected JSON value: {obj!r}")


def loads(data: str | bytes) -> Table:
    """Read a tagged JSON document into a :class:`~tomlcodec.model.Table`.

    Raises :class:`~tomlcodec.errors.TaggedJsonError` if the input is not
    JSON or its root is not an object.
    """
    try:
        obj = json.loads(data)
    except (ValueError, RecursionError) as exc:
        raise TaggedJsonError(str(exc)) from None
    if not isinstance(obj, dict):
        raise TaggedJsonError("the root of a tagged JSON document must be an object")
    root = _convert(obj)
    if not isinstance(root, Table):
        raise TaggedJsonError("the root of a tagged JSON document must be a table")
    return root
