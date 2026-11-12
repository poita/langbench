"""Shared test helpers: an invariant checker for whole database images."""

from __future__ import annotations

import struct

from tessera import Database
from tessera.constants import CAPACITY, PAGE_INTERIOR, PAGE_LEAF, PAGE_SIZE
from tessera.pages import decode, encode


def view(db: Database):
    """The pager of a database (tests look below the public API)."""
    return db._pager


def check_tree(pager, root: int, leaf_type: int):
    """Verify every structural invariant of one tree; return (keys in order, pages used)."""
    pages: list[int] = []
    leaves: list[tuple[int, list[bytes], int]] = []
    depths: set[int] = set()

    def walk(p: int, lo, hi, depth: int, is_root: bool):
        raw = pager.read(p)
        node = decode(p, raw)
        pages.append(p)
        assert encode(node) == raw, f"page {p} is not canonical"
        assert node.used() <= CAPACITY
        assert node.keys == sorted(node.keys) and len(set(node.keys)) == len(node.keys)
        if not is_root:
            assert node.keys or node.type == PAGE_INTERIOR and False, f"empty non-root page {p}"
        for k in node.keys:
            assert (lo is None or k > lo) and (hi is None or k <= hi), f"key out of range on {p}"
        if node.type == PAGE_INTERIOR:
            assert node.keys, f"interior page {p} without cells"
            bounds = [lo] + node.keys
            for i, child in enumerate(node.vals):
                walk(child, bounds[i], node.keys[i], depth + 1, False)
            walk(node.link, node.keys[-1], hi, depth + 1, False)
        else:
            assert node.type == leaf_type
            depths.add(depth)
            leaves.append((p, node.keys, node.link))

    if root == 0:
        return [], []
    walk(root, None, None, 1, True)
    assert len(depths) == 1, "leaves at different depths"
    for (p, _, link), nxt in zip(leaves, leaves[1:] + [(0, [], 0)]):
        assert link == nxt[0], f"leaf {p} links to {link}, expected {nxt[0]}"
    keys = [k for _, ks, _ in leaves for k in ks]
    assert keys == sorted(keys)
    return keys, pages


def check_database(db: Database) -> None:
    """Every page is either the header, in one tree, an overflow page, or on the free list."""
    pager = view(db)
    h = pager.header
    seen: list[int] = [1]
    keys, pages = check_tree(pager, h.primary_root, PAGE_LEAF)
    seen += pages
    assert len(keys) == h.primary_count
    for cell_key in keys:
        doc_len, overflow, inline = db._primary().get(cell_key)
        assert len(inline) == min(doc_len, 192)
        p = overflow
        remaining = doc_len - len(inline)
        while p:
            seen.append(p)
            page = pager.read(p)
            _, nxt, plen = struct.unpack_from(">B3xIH", page)
            assert page[0] == 3 and 1 <= plen <= 1012 and not any(page[12 + plen:])
            remaining -= plen
            p = nxt
        assert remaining == 0
    for s, slot in enumerate(h.slots):
        if slot is None:
            continue
        ikeys, ipages = check_tree(pager, slot.root, 5)
        assert len(ikeys) == slot.entries
        seen += ipages
    p, free = h.freelist_head, 0
    while p:
        seen.append(p)
        page = pager.read(p)
        assert page == struct.pack(">B3xI", 0, struct.unpack_from(">I", page, 4)[0]) + bytes(PAGE_SIZE - 8)
        p = struct.unpack_from(">I", page, 4)[0]
        free += 1
    assert free == h.freelist_count
    assert sorted(seen) == list(range(1, h.page_count + 1)), "leaked or double-used pages"
