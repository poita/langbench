"""The tagged-JSON interchange format of the ``toml-test`` suite.

Tables are JSON objects, arrays are JSON arrays and scalars are objects of the
form ``{"type": ..., "value": ...}`` whose ``value`` is always a string.
"""

from __future__ import annotations

import json

from .errors import TaggedJSONError
from .model import SCALAR_TYPES, Scalar, Table

_STRING_ENCODER = json.JSONEncoder(ensure_ascii=False)
_quote = _STRING_ENCODER.encode  # str -> JSON string literal, non-ASCII kept literal


def to_tagged_json(tree: Table) -> str:
    """Serialise *tree* as compact, key-sorted tagged JSON (no trailing newline)."""
    out: list[str] = []
    _emit(tree, out)
    return "".join(out)


def _emit(node: object, out: list[str]) -> None:
    if isinstance(node, Scalar):
        out.append('{"type":"%s","value":%s}' % (node.type, _quote(node.text)))
    elif isinstance(node, dict):
        out.append("{")
        first = True
        for key in sorted(node):  # code point order
            if first:
                first = False
            else:
                out.append(",")
            out.append(_quote(key))
            out.append(":")
            _emit(node[key], out)
        out.append("}")
    elif isinstance(node, list):
        out.append("[")
        first = True
        for item in node:
            if first:
                first = False
            else:
                out.append(",")
            _emit(item, out)
        out.append("]")
    else:
        raise TypeError(f"cannot serialise {type(node).__name__}")


def from_tagged_json(text: str | bytes) -> Table:
    """Parse tagged JSON into a tree (the inverse of :func:`to_tagged_json`).

    A JSON object is a scalar node exactly when it has the two members
    ``type`` and ``value``, both strings, with ``type`` one of
    :data:`~tomlcodec.model.SCALAR_TYPES`; otherwise it is a table.
    Raises :class:`~tomlcodec.errors.TaggedJSONError` on malformed input.
    """
    try:
        raw = json.loads(text)
    except (ValueError, RecursionError) as exc:
        raise TaggedJSONError(f"invalid JSON: {exc}") from None
    if not isinstance(raw, dict):
        raise TaggedJSONError("the root of a tagged-JSON document must be an object")
    try:
        node = _convert(raw)
    except RecursionError:
        raise TaggedJSONError("document is nested too deeply") from None
    if not isinstance(node, Table):
        raise TaggedJSONError("the root of a tagged-JSON document must be a table")
    return node


def _convert(raw: object) -> object:
    if isinstance(raw, dict):
        if len(raw) == 2:
            kind = raw.get("type")
            value = raw.get("value")
            if isinstance(kind, str) and isinstance(value, str) and kind in SCALAR_TYPES:
                return Scalar(kind, value)
        table = Table()
        for key, value in raw.items():
            table[key] = _convert(value)
        return table
    if isinstance(raw, list):
        return [_convert(item) for item in raw]
    raise TaggedJSONError(f"unexpected JSON value {raw!r}")
