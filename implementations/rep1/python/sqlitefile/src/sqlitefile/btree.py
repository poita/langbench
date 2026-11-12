"""B-tree traversal (spec sections 1.2, 1.4, 1.6 and 1.7).

The functions here know nothing about records or SQL: they hand back raw cell
payloads (``bytes``) and leave decoding to the caller.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator

from .errors import FormatError
from .pager import INTERIOR_INDEX, INTERIOR_TABLE, LEAF_INDEX, LEAF_TABLE, Page, Pager
from .varint import read_varint

#: Deeper than any real B-tree; guards against cycles in corrupt files.
MAX_DEPTH = 64


def _table_leaf_cell(pager: Pager, pos: int) -> tuple[int, bytes]:
    size, pos = read_varint(pager.data, pos)
    rowid, pos = read_varint(pager.data, pos)
    return rowid, pager.read_payload(pos, size, pager.max_local_table)


def _table_interior_cell(pager: Pager, pos: int) -> tuple[int, int]:
    child = pager.u32(pos)
    key, _ = read_varint(pager.data, pos + 4)
    return child, key


def _index_cell(pager: Pager, page: Page, i: int) -> tuple[int, bytes]:
    """Return ``(left_child, payload)`` of cell ``i`` (child is 0 on leaves)."""
    pos = page.cells[i]
    child = 0
    if page.kind == INTERIOR_INDEX:
        child = pager.u32(pos)
        pos += 4
    size, pos = read_varint(pager.data, pos)
    return child, pager.read_payload(pos, size, pager.max_local_index)


def iter_table(pager: Pager, root: int) -> Iterator[tuple[int, bytes]]:
    """Yield ``(rowid, payload)`` for every row of a table B-tree, in rowid order."""
    yield from _iter_table(pager, root, 0)


def _iter_table(pager: Pager, pno: int, depth: int) -> Iterator[tuple[int, bytes]]:
    if depth > MAX_DEPTH:
        raise FormatError("B-tree too deep")
    page = pager.read_page(pno)
    if page.kind == LEAF_TABLE:
        for pos in page.cells:
            yield _table_leaf_cell(pager, pos)
    elif page.kind == INTERIOR_TABLE:
        for pos in page.cells:
            yield from _iter_table(pager, pager.u32(pos), depth + 1)
        yield from _iter_table(pager, page.right_child, depth + 1)
    else:
        raise FormatError(f"page {pno} is not a table B-tree page")


def count_table(pager: Pager, root: int, _depth: int = 0) -> int:
    """Number of rows in a table B-tree, from leaf cell counts alone."""
    if _depth > MAX_DEPTH:
        raise FormatError("B-tree too deep")
    page = pager.read_page(root)
    if page.kind == LEAF_TABLE:
        return len(page.cells)
    if page.kind != INTERIOR_TABLE:
        raise FormatError(f"page {root} is not a table B-tree page")
    total = count_table(pager, page.right_child, _depth + 1)
    for pos in page.cells:
        total += count_table(pager, pager.u32(pos), _depth + 1)
    return total


def find_row(pager: Pager, root: int, rowid: int) -> bytes | None:
    """Look up one row by rowid, returning its payload or ``None``."""
    pno = root
    for _ in range(MAX_DEPTH):
        page = pager.read_page(pno)
        cells = page.cells
        if page.kind == LEAF_TABLE:
            lo, hi = 0, len(cells)
            while lo < hi:
                mid = (lo + hi) // 2
                key, _ = read_varint(pager.data, _skip_varint(pager, cells[mid]))
                if key < rowid:
                    lo = mid + 1
                else:
                    hi = mid
            if lo < len(cells):
                found, payload = _table_leaf_cell(pager, cells[lo])
                if found == rowid:
                    return payload
            return None
        if page.kind != INTERIOR_TABLE:
            raise FormatError(f"page {pno} is not a table B-tree page")
        lo, hi = 0, len(cells)
        while lo < hi:  # first cell whose key >= rowid
            mid = (lo + hi) // 2
            _, key = _table_interior_cell(pager, cells[mid])
            if key < rowid:
                lo = mid + 1
            else:
                hi = mid
        pno = pager.u32(cells[lo]) if lo < len(cells) else page.right_child
    raise FormatError("B-tree too deep")


def _skip_varint(pager: Pager, pos: int) -> int:
    """Position just past the varint at ``pos`` (the payload-size field)."""
    return read_varint(pager.data, pos)[1]


def index_equal(
    pager: Pager, root: int, compare: Callable[[bytes], int]
) -> Iterator[bytes]:
    """Yield, in key order, the payloads of index entries matching a probe.

    ``compare(payload)`` must return a negative, zero or positive number as the
    entry sorts before, equal to or after the sought key. Entries are visited
    by descending only into subtrees that can hold matches, so the cost is
    ``O(depth * log(cells) + matches)`` and interior cells are emitted between
    their subtrees (spec section 1.7).
    """
    yield from _index_equal(pager, root, compare, 0)


def _index_equal(
    pager: Pager, pno: int, compare: Callable[[bytes], int], depth: int
) -> Iterator[bytes]:
    if depth > MAX_DEPTH:
        raise FormatError("B-tree too deep")
    page = pager.read_page(pno)
    if page.kind not in (LEAF_INDEX, INTERIOR_INDEX):
        raise FormatError(f"page {pno} is not an index B-tree page")
    n = len(page.cells)
    lo, hi = 0, n  # binary search: first cell that is not smaller than the key
    while lo < hi:
        mid = (lo + hi) // 2
        if compare(_index_cell(pager, page, mid)[1]) < 0:
            lo = mid + 1
        else:
            hi = mid
    if page.kind == LEAF_INDEX:
        for i in range(lo, n):
            payload = _index_cell(pager, page, i)[1]
            if compare(payload) != 0:
                return
            yield payload
        return
    for i in range(lo, n):
        child, payload = _index_cell(pager, page, i)
        yield from _index_equal(pager, child, compare, depth + 1)
        if compare(payload) != 0:
            return
        yield payload
    yield from _index_equal(pager, page.right_child, compare, depth + 1)
