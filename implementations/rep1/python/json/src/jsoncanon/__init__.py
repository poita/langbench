"""jsoncanon: a strict JSON parser and canonical serializer.

Public API:

* :func:`parse` -- bytes -> value tree (raises :class:`JSONError`)
* :func:`dumps` / :func:`dump` -- value tree -> canonical ``str`` / ``bytes``
* :func:`canonicalize` -- bytes -> canonical bytes in one call
* :class:`Number`, :class:`Object` -- tree node types for numbers and objects
* :data:`MAX_DEPTH` -- maximum nesting depth (512)
"""

from __future__ import annotations

from .errors import JSONError
from .parser import MAX_DEPTH, decode_utf8, parse_text
from .serializer import dump, dump_text as dumps
from .values import Number, Object

__all__ = [
    "JSONError",
    "MAX_DEPTH",
    "Number",
    "Object",
    "canonicalize",
    "dump",
    "dumps",
    "parse",
    "loads",
]

__version__ = "1.0.0"


def parse(data: bytes | bytearray | memoryview | str):
    """Parse one JSON document.

    ``data`` is normally the raw bytes of the document, which are validated
    as strict UTF-8 (a BOM is rejected).  A ``str`` is accepted as already
    decoded text.  Numbers become :class:`Number` (canonical text, never
    floats), objects become :class:`Object` (members in input order,
    duplicates kept), arrays ``list``, literals ``True``/``False``/``None``.

    Raises:
        JSONError: the document is invalid under RFC 8259 as restricted by
            the specification (strict UTF-8, depth <= :data:`MAX_DEPTH`).
    """
    text = data if isinstance(data, str) else decode_utf8(data)
    return parse_text(text)


loads = parse


def canonicalize(data: bytes | bytearray | memoryview | str) -> bytes:
    """Parse ``data`` and return its canonical serialization as UTF-8 bytes.

    Object keys are deduplicated (last wins) and sorted by UTF-16 code
    units, insignificant whitespace is removed, strings use minimal
    escaping and number exponents are normalised.

    Raises:
        JSONError: the document is invalid.
    """
    return dump(parse(data))
