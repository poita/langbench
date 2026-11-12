"""Overflow page chains for documents longer than MAX_INLINE (SPEC §9)."""

from __future__ import annotations

import struct

from .constants import MAX_INLINE, OVF_PAYLOAD, PAGE_OVERFLOW
from .pager import Pager

_HEAD = struct.Struct(">B3xIH2x")


def write_chain(pager: Pager, data: bytes) -> int:
    """Store ``data`` (the document bytes beyond the inline part) in a new chain.

    Pages are allocated in chain order, first chunk first. Returns the first
    page number, or 0 when ``data`` is empty.
    """
    if not data:
        return 0
    chunks = [data[i:i + OVF_PAYLOAD] for i in range(0, len(data), OVF_PAYLOAD)]
    pages = [pager.allocate() for _ in chunks]
    for i, chunk in enumerate(chunks):
        nxt = pages[i + 1] if i + 1 < len(pages) else 0
        pager.write(pages[i], _HEAD.pack(PAGE_OVERFLOW, nxt, len(chunk)) + chunk.ljust(OVF_PAYLOAD, b"\x00"))
    return pages[0]


def chain_pages(pager: Pager, first: int) -> list[int]:
    """Page numbers of a chain, in chain order."""
    pages = []
    p = first
    while p:
        pages.append(p)
        p = _HEAD.unpack_from(pager.read(p))[1]
    return pages


def free_chain(pager: Pager, first: int) -> None:
    """Free a chain in chain order, so its last page ends up at the free-list head."""
    for p in chain_pages(pager, first):
        pager.free(p)


def read_document_bytes(pager: Pager, doc_len: int, overflow: int, inline: bytes) -> bytes:
    """Reassemble a serialised document from its leaf cell and overflow chain."""
    if not overflow:
        return inline
    parts = [inline]
    p = overflow
    while p:
        page = pager.read(p)
        _, nxt, plen = _HEAD.unpack_from(page)
        parts.append(page[12:12 + plen])
        p = nxt
    return b"".join(parts)


def split_document(data: bytes) -> tuple[bytes, bytes]:
    """Split serialised document bytes into (inline part, overflow part)."""
    return data[:MAX_INLINE], data[MAX_INLINE:]
