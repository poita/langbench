"""Canonical B+tree page encoding and decoding (SPEC §11)."""

from __future__ import annotations

import struct
from typing import Any

from .constants import BTREE_HEADER, CAPACITY, PAGE_INTERIOR, PAGE_LEAF, PAGE_SIZE

_HEAD = struct.Struct(">BxHHxxII")
_LEAF_CELL = struct.Struct(">HIHI")
_INT_CELL = struct.Struct(">HI")
_U16 = struct.Struct(">H")


class Node:
    """The logical content of one B+tree page: ordered cells plus the header link.

    ``keys`` and ``vals`` are parallel lists. The value of a cell is

    * primary leaf:  ``(doc_len, overflow_page, inline_bytes)``
    * interior:      the child page number
    * index leaf:    ``None``

    ``link`` is the rightmost child (interior) or the next leaf (leaf).
    """

    __slots__ = ("page_no", "type", "keys", "vals", "link")

    def __init__(self, page_no: int, type_: int, keys: list[bytes], vals: list[Any], link: int):
        self.page_no = page_no
        self.type = type_
        self.keys = keys
        self.vals = vals
        self.link = link

    @property
    def is_leaf(self) -> bool:
        return self.type != PAGE_INTERIOR

    def costs(self) -> list[int]:
        """Per-cell cost: the encoded cell size plus its 2-byte pointer."""
        t = self.type
        if t == PAGE_LEAF:
            return [14 + len(k) + len(v[2]) for k, v in zip(self.keys, self.vals)]
        if t == PAGE_INTERIOR:
            return [8 + len(k) for k in self.keys]
        return [4 + len(k) for k in self.keys]

    def used(self) -> int:
        """Payload size of the page (SPEC §11.2)."""
        return sum(self.costs())

    def overflows(self) -> bool:
        return self.used() > CAPACITY


def decode(page_no: int, data: bytes) -> Node:
    """Decode a leaf or interior page image."""
    type_, n, _start, link, _ = _HEAD.unpack_from(data, 0)
    ptrs = struct.unpack_from(">%dH" % n, data, BTREE_HEADER)
    keys: list[bytes] = []
    vals: list[Any] = []
    if type_ == PAGE_LEAF:
        for p in ptrs:
            kl, doc_len, inline_len, overflow = _LEAF_CELL.unpack_from(data, p)
            ks = p + 12
            keys.append(data[ks:ks + kl])
            vals.append((doc_len, overflow, data[ks + kl:ks + kl + inline_len]))
    elif type_ == PAGE_INTERIOR:
        for p in ptrs:
            kl, child = _INT_CELL.unpack_from(data, p)
            keys.append(data[p + 6:p + 6 + kl])
            vals.append(child)
    else:
        for p in ptrs:
            kl = _U16.unpack_from(data, p)[0]
            keys.append(data[p + 2:p + 2 + kl])
            vals.append(None)
    return Node(page_no, type_, keys, vals, link)


def encode(node: Node) -> bytes:
    """Encode a node into its unique canonical 1024-byte page."""
    t = node.type
    cells: list[bytes] = []
    if t == PAGE_LEAF:
        for k, (doc_len, overflow, inline) in zip(node.keys, node.vals):
            cells.append(_LEAF_CELL.pack(len(k), doc_len, len(inline), overflow) + k + inline)
    elif t == PAGE_INTERIOR:
        for k, child in zip(node.keys, node.vals):
            cells.append(_INT_CELL.pack(len(k), child) + k)
    else:
        for k in node.keys:
            cells.append(_U16.pack(len(k)) + k)
    n = len(cells)
    total = sum(map(len, cells))
    start = PAGE_SIZE - total if n else PAGE_SIZE
    ptrs = []
    off = start
    for c in cells:
        ptrs.append(off)
        off += len(c)
    head = _HEAD.pack(t, n, start, node.link, 0)
    ptr_bytes = struct.pack(">%dH" % n, *ptrs)
    gap = start - BTREE_HEADER - 2 * n
    return head + ptr_bytes + bytes(gap) + b"".join(cells)


def empty_leaf(page_no: int, leaf_type: int) -> Node:
    return Node(page_no, leaf_type, [], [], 0)


def split_point(costs: list[int]) -> int:
    """SPEC §12.3: the smallest ``m`` in ``1 .. n-1`` with ``2 * P[m] >= T``."""
    total = sum(costs)
    acc = 0
    for m in range(1, len(costs)):
        acc += costs[m - 1]
        if 2 * acc >= total:
            return m
    raise AssertionError("page cannot be split")
