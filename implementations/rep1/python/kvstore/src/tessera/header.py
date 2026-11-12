"""The header page and the index directory (SPEC §7, §8)."""

from __future__ import annotations

import struct

from .constants import MAX_INDEXES, PAGE_SIZE

MAGIC = b"TESSERA1"
_HEAD = struct.Struct(">8sHHIIIIIQI")
_SLOT = struct.Struct(">BB30sII8x")
_DIR_OFFSET = 128
_SLOT_SIZE = 48


class IndexSlot:
    """A live entry of the index directory."""

    __slots__ = ("path", "segs", "root", "entries")

    def __init__(self, path: str, root: int = 0, entries: int = 0):
        self.path = path                      # path text, segments joined by '.'
        self.segs = tuple(path.split("."))
        self.root = root                      # root page of the index tree, 0 = empty
        self.entries = entries                # number of entries in the tree

    def copy(self) -> "IndexSlot":
        return IndexSlot(self.path, self.root, self.entries)


class Header:
    """Decoded contents of page 1.

    Page 1 is canonical: its 1024 bytes are a pure function of these fields.
    """

    __slots__ = ("page_count", "freelist_head", "freelist_count", "primary_root",
                 "primary_count", "commit_counter", "slots")

    def __init__(self) -> None:
        self.page_count = 1
        self.freelist_head = 0
        self.freelist_count = 0
        self.primary_root = 0
        self.primary_count = 0
        self.commit_counter = 0
        self.slots: list[IndexSlot | None] = [None] * MAX_INDEXES

    @property
    def index_count(self) -> int:
        return sum(1 for s in self.slots if s is not None)

    def copy(self) -> "Header":
        h = Header()
        h.page_count = self.page_count
        h.freelist_head = self.freelist_head
        h.freelist_count = self.freelist_count
        h.primary_root = self.primary_root
        h.primary_count = self.primary_count
        h.commit_counter = self.commit_counter
        h.slots = [s.copy() if s is not None else None for s in self.slots]
        return h

    @classmethod
    def decode(cls, page: bytes) -> "Header":
        h = cls()
        (_magic, _ver, _psize, h.page_count, h.freelist_head, h.freelist_count,
         h.primary_root, h.primary_count, h.commit_counter, _n) = _HEAD.unpack_from(page, 0)
        for s in range(MAX_INDEXES):
            live, plen, path, root, entries = _SLOT.unpack_from(page, _DIR_OFFSET + s * _SLOT_SIZE)
            if live:
                h.slots[s] = IndexSlot(path[:plen].decode("utf-8"), root, entries)
        return h

    def encode(self) -> bytes:
        parts = [_HEAD.pack(MAGIC, 1, PAGE_SIZE, self.page_count, self.freelist_head,
                            self.freelist_count, self.primary_root, self.primary_count,
                            self.commit_counter, self.index_count)]
        parts.append(bytes(_DIR_OFFSET - _HEAD.size))
        for slot in self.slots:
            if slot is None:
                parts.append(bytes(_SLOT_SIZE))
            else:
                raw = slot.path.encode("utf-8")
                parts.append(_SLOT.pack(1, len(raw), raw, slot.root, slot.entries))
        parts.append(bytes(PAGE_SIZE - _DIR_OFFSET - MAX_INDEXES * _SLOT_SIZE))
        return b"".join(parts)


def fresh_page() -> bytes:
    """Page 1 of a fresh database (SPEC §7.3)."""
    return Header().encode()
