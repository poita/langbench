"""tomlcodec: a from-scratch TOML 1.0.0 parser and canonical serializer.

Public API
----------
``loads(data)``
    Parse TOML text (or UTF-8 bytes) into a :class:`Table` tree.
``dumps(table)``
    Write a tree as canonical TOML.
``to_tagged_json(table)`` / ``from_tagged_json(text)``
    Convert a tree to / from the ``toml-test`` tagged JSON format.
``decode(data)`` / ``encode(json_text)``
    The two CLI operations: TOML to tagged JSON and back.

Scalars are kept as canonical text (see :class:`Scalar`); nothing is
converted to Python numbers or datetimes.
"""

from __future__ import annotations

from .decoder import loads
from .encoder import dumps
from .errors import TaggedJsonError, TomlDecodeError
from .model import Array, Scalar, Table
from .tagged import dumps as to_tagged_json
from .tagged import loads as from_tagged_json

__all__ = [
    "Array",
    "Scalar",
    "TaggedJsonError",
    "Table",
    "TomlDecodeError",
    "decode",
    "dumps",
    "encode",
    "from_tagged_json",
    "loads",
    "to_tagged_json",
]

__version__ = "0.1.0"


def decode(data: str | bytes) -> str:
    """Parse a TOML document and return it as compact tagged JSON.

    Raises :class:`TomlDecodeError` if the document is invalid.
    """
    return to_tagged_json(loads(data))


def encode(json_text: str | bytes) -> str:
    """Convert tagged JSON to a canonical TOML document."""
    return dumps(from_tagged_json(json_text))
