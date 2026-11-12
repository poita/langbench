"""Index key encoding (SPEC §14.1).

An index entry's key is ``vkey(value) || document_key``; ``vkey`` is an
order-preserving, self-delimiting encoding of the indexed field value.
"""

from __future__ import annotations

from typing import Any

from .value import MISSING, get_path

_NULL = b"\x10"
_FALSE = b"\x20"
_TRUE = b"\x21"


def vkey(v: Any) -> bytes | None:
    """The ``vkey`` of a scalar value, or ``None`` for a list or object."""
    if v is None:
        return _NULL
    t = type(v)
    if t is bool:
        return _TRUE if v else _FALSE
    if t is int:
        return b"\x30" + (v + (1 << 63)).to_bytes(8, "big")
    if t is str:
        return b"\x40" + v.encode("utf-8").replace(b"\x00", b"\x00\xff") + b"\x00\x00"
    return None


def vkey_length(entry: bytes) -> int:
    """Length of the ``vkey`` at the start of an index key."""
    tag = entry[0]
    if tag == 0x30:
        return 9
    if tag != 0x40:
        return 1
    i = 1
    while True:
        j = entry.index(b"\x00", i)
        if entry[j + 1] == 0xFF:
            i = j + 2
        else:
            return j + 2


def entry_key(doc: Any, segs: tuple[str, ...], key: bytes) -> bytes | None:
    """Index key of ``doc`` (stored under ``key``) for the index on ``segs``.

    ``None`` when the document has no entry in that index: the path is missing
    or resolves to a list or an object (SPEC §14.2).
    """
    v = get_path(doc, segs)
    if v is MISSING:
        return None
    vk = vkey(v)
    return None if vk is None else vk + key
