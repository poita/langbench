"""Canonical B+tree pages and the tree algorithms: SPEC.md §9, §11, §12.

A page's logical content is a `Page`: its type byte, its cells in ascending key
order and its one `link` pointer. Every cell is a tuple whose first element is
the cell's key, so the tree code can compare cells without knowing their kind:

    primary leaf (type 1): (key, doc_len, overflow, inline)
    interior     (type 2): (key, child)
    index leaf   (type 5): (key,)

Each modification re-encodes the whole page from its logical content (§11.2),
which is what makes the 1024 bytes a pure function of the content.
"""

from struct import pack, unpack_from

from tpager import (PAGE_SIZE, PT_LEAF, PT_INTERIOR, PT_INDEX_LEAF, PT_OVERFLOW)

BTREE_HEADER = 16
CAPACITY = 1008
MIN_FILL = 336
MAX_INLINE = 192
OVF_PAYLOAD = 1012


class Page(object):
    __slots__ = ("ptype", "cells", "link")

    def __init__(self, ptype, cells, link):
        self.ptype = ptype
        self.cells = cells
        self.link = link


def cell_size(ptype, cell):
    if ptype == PT_LEAF:
        return 12 + len(cell[0]) + len(cell[3])
    if ptype == PT_INTERIOR:
        return 6 + len(cell[0])
    return 2 + len(cell[0])


def cell_cost(ptype, cell):
    """The cell's size plus the two bytes of its pointer (§11.6)."""
    return cell_size(ptype, cell) + 2


def encode_cell(ptype, cell):
    if ptype == PT_LEAF:
        key, doc_len, overflow, inline = cell
        return pack(">HIHI", len(key), doc_len, len(inline), overflow) + key + inline
    if ptype == PT_INTERIOR:
        key, child = cell
        return pack(">HI", len(key), child) + key
    return pack(">H", len(cell[0])) + cell[0]


def used(page):
    """The payload size of a page: 2 bytes per pointer plus the cells (§11.2)."""
    ptype = page.ptype
    total = 2 * len(page.cells)
    for c in page.cells:
        total += cell_size(ptype, c)
    return total


def encode_page(page):
    """The canonical 1024 bytes of §11.2. An overfull page has no such bytes,
    so encoding one is a bug in the caller."""
    assert used(page) <= CAPACITY, "encoding an overfull page"
    bodies = [encode_cell(page.ptype, c) for c in page.cells]
    n = len(bodies)
    size = sum(len(b) for b in bodies)
    cell_start = PAGE_SIZE - size
    out = bytearray(PAGE_SIZE)
    out[0] = page.ptype
    out[2:6] = pack(">HH", n, cell_start)
    out[8:12] = pack(">I", page.link)
    offsets = []
    off = cell_start
    for b in bodies:
        offsets.append(off)
        off += len(b)
    if n:
        out[BTREE_HEADER:BTREE_HEADER + 2 * n] = pack(">%dH" % n, *offsets)
        out[cell_start:PAGE_SIZE] = b"".join(bodies)
    return bytes(out)


def decode_page(image):
    """The inverse of encode_page. `image` is a bytes object, so the slices
    taken here are already immutable and need no further copying."""
    ptype = image[0]
    n = unpack_from(">H", image, 2)[0]
    link = unpack_from(">I", image, 8)[0]
    cells = []
    offsets = unpack_from(">%dH" % n, image, BTREE_HEADER) if n else ()
    if ptype == PT_LEAF:
        for off in offsets:
            key_len, doc_len, inline_len, overflow = unpack_from(">HIHI", image, off)
            base = off + 12
            cells.append((image[base:base + key_len], doc_len, overflow,
                          image[base + key_len:base + key_len + inline_len]))
    elif ptype == PT_INTERIOR:
        for off in offsets:
            key_len, child = unpack_from(">HI", image, off)
            cells.append((image[off + 6:off + 6 + key_len], child))
    else:
        for off in offsets:
            key_len = unpack_from(">H", image, off)[0]
            cells.append((image[off + 2:off + 2 + key_len],))
    return Page(ptype, cells, link)


def empty_page_image(ptype):
    return encode_page(Page(ptype, [], 0))


def _lower_bound(cells, key):
    """The smallest index i with cells[i][0] >= key."""
    lo, hi = 0, len(cells)
    while lo < hi:
        mid = (lo + hi) // 2
        if cells[mid][0] < key:
            lo = mid + 1
        else:
            hi = mid
    return lo


# --------------------------------------------------------------------------
# Overflow chains (§9)
# --------------------------------------------------------------------------

def overflow_page_image(nxt, payload):
    p = bytearray(PAGE_SIZE)
    p[0] = PT_OVERFLOW
    p[4:8] = nxt.to_bytes(4, "big")
    p[8:10] = len(payload).to_bytes(2, "big")
    p[12:12 + len(payload)] = payload
    return bytes(p)


def write_overflow_chain(pager, tail):
    """Store the document bytes past MAX_INLINE; return the first page number.

    The chain's pages are allocated in chain order, first chunk first (§9).
    """
    chunks = [tail[i:i + OVF_PAYLOAD] for i in range(0, len(tail), OVF_PAYLOAD)]
    pages = [pager.allocate_page() for _ in chunks]
    for i, chunk in enumerate(chunks):
        nxt = pages[i + 1] if i + 1 < len(pages) else 0
        pager.write_page(pages[i], overflow_page_image(nxt, chunk))
    return pages[0]


def free_overflow_chain(pager, first):
    """Free a chain in chain order, so its last page ends up at the head."""
    p = first
    while p:
        image = pager.read_page(p)
        nxt = int.from_bytes(image[4:8], "big")
        pager.free_page(p)
        p = nxt


def read_overflow_chain(pager, first, want):
    out = []
    got = 0
    p = first
    while p and got < want:
        image = pager.read_page(p)
        n = int.from_bytes(image[8:10], "big")
        out.append(bytes(image[12:12 + n]))
        got += n
        p = int.from_bytes(image[4:8], "big")
    return b"".join(out)


# --------------------------------------------------------------------------
# The tree
# --------------------------------------------------------------------------

class Tree(object):
    """One B+tree. `leaf_type` is PT_LEAF or PT_INDEX_LEAF; the root page
    number lives wherever `get_root` and `set_root` put it (§12)."""

    def __init__(self, pager, leaf_type, get_root, set_root):
        self.pager = pager
        self.leaf_type = leaf_type
        self.get_root = get_root
        self.set_root = set_root

    # ---- reading ---------------------------------------------------------

    def _read(self, p):
        return decode_page(self.pager.read_page(p))

    def _write(self, p, page):
        self.pager.write_page(p, encode_page(page))

    def _descend(self, key, path):
        """Walk from the root to the leaf that would hold `key`, appending
        (page number, chosen child index) pairs to `path` (§12.1)."""
        p = self.get_root()
        if p == 0:
            return 0, None
        page = self._read(p)
        while page.ptype == PT_INTERIOR:
            i = _lower_bound(page.cells, key)
            path.append((p, i))
            p = page.link if i == len(page.cells) else page.cells[i][1]
            page = self._read(p)
        return p, page

    def find(self, key):
        """(leaf page number, cell) for `key`, or (0, None) when absent."""
        p, page = self._descend(key, [])
        if p == 0:
            return 0, None
        i = _lower_bound(page.cells, key)
        if i < len(page.cells) and page.cells[i][0] == key:
            return p, page.cells[i]
        return p, None

    def height(self):
        p = self.get_root()
        if p == 0:
            return 0
        h = 0
        while True:
            page = self._read(p)
            h += 1
            if page.ptype != PT_INTERIOR:
                return h
            p = page.cells[0][1] if page.cells else page.link

    def leftmost_leaf(self):
        p = self.get_root()
        if p == 0:
            return 0
        while True:
            page = self._read(p)
            if page.ptype != PT_INTERIOR:
                return p
            p = page.cells[0][1] if page.cells else page.link

    def iter_cells(self, start=None):
        """Every cell in ascending key order (§12.6), optionally from a key."""
        if start is None:
            p = self.leftmost_leaf()
            first = 0
        else:
            path = []
            p, page = self._descend(start, path)
            if p == 0:
                return
            first = _lower_bound(page.cells, start)
        while p:
            page = self._read(p)
            cells = page.cells
            for i in range(first, len(cells)):
                yield cells[i]
            first = 0
            p = page.link

    def all_pages_postorder(self, p=None):
        """Page numbers in post-order page order, for freeing a tree (§12.6)."""
        if p is None:
            p = self.get_root()
            if p == 0:
                return
        page = self._read(p)
        if page.ptype == PT_INTERIOR:
            for c in page.cells:
                for q in self.all_pages_postorder(c[1]):
                    yield q
            if page.link:
                for q in self.all_pages_postorder(page.link):
                    yield q
        yield p

    # ---- insert (§12.2) --------------------------------------------------

    def insert(self, cell):
        """Insert or replace a cell; return True when an existing key was
        replaced."""
        key = cell[0]
        if self.get_root() == 0:
            r = self.pager.allocate_page()
            self.pager.write_page(r, empty_page_image(self.leaf_type))
            self.set_root(r)
        path = []
        p, page = self._descend(key, path)
        i = _lower_bound(page.cells, key)
        replaced = i < len(page.cells) and page.cells[i][0] == key
        if replaced:
            page.cells[i] = cell
        else:
            page.cells.insert(i, cell)
        self._store(p, page, path)
        return replaced

    def _store(self, p, page, path):
        """Write a page, splitting it instead when it has overflowed. An
        overfull page is never encoded: it has no canonical 1024 bytes."""
        if used(page) > CAPACITY:
            self._split(p, page, path)
        else:
            self._write(p, page)

    def _split_point(self, page):
        ptype = page.ptype
        w = [cell_cost(ptype, c) for c in page.cells]
        total = sum(w)
        half = 0
        for m in range(1, len(w)):
            half += w[m - 1]
            if 2 * half >= total:
                return m
        raise AssertionError("no split point")

    def _split(self, p, page, path):
        m = self._split_point(page)
        cells = page.cells
        if page.ptype == PT_INTERIOR:
            promoted = cells[m - 1]
            right_cells = cells[m:]
            right = self.pager.allocate_page()
            self._write(right, Page(PT_INTERIOR, right_cells, page.link))
            page.cells = cells[:m - 1]
            page.link = promoted[1]
            self._write(p, page)
            sep = promoted[0]
        else:
            right_cells = cells[m:]
            right = self.pager.allocate_page()
            self._write(right, Page(page.ptype, right_cells, page.link))
            page.cells = cells[:m]
            page.link = right
            self._write(p, page)
            sep = page.cells[-1][0]
        self._install(p, right, sep, path)

    def _install(self, left, right, sep, path):
        """Put the separator into the parent, growing the tree if needed."""
        if not path:
            newroot = self.pager.allocate_page()
            self._write(newroot, Page(PT_INTERIOR, [(sep, left)], right))
            self.set_root(newroot)
            return
        parent_no, j = path[-1]
        parent = self._read(parent_no)
        if j == len(parent.cells):
            parent.cells.append((sep, left))
            parent.link = right
        else:
            parent.cells[j] = (parent.cells[j][0], right)
            parent.cells.insert(j, (sep, left))
        self._store(parent_no, parent, path[:-1])

    # ---- delete (§12.4, §12.5) -------------------------------------------

    def delete(self, key):
        """Remove `key`; return False when it was not there."""
        path = []
        p, page = self._descend(key, path)
        if p == 0:
            return False
        i = _lower_bound(page.cells, key)
        if i >= len(page.cells) or page.cells[i][0] != key:
            return False
        del page.cells[i]
        self._write(p, page)
        if not path:
            if not page.cells:
                self.pager.free_page(p)
                self.set_root(0)
            return True
        if used(page) >= MIN_FILL:
            return True
        self._repair(p, page, path)
        return True

    def _repair(self, n_no, n_page, path):
        parent_no, j = path[-1]
        parent = self._read(parent_no)
        n_parent = len(parent.cells)
        left_no = parent.cells[j - 1][1] if j >= 1 else 0
        if j < n_parent:
            right_no = parent.cells[j + 1][1] if j + 1 < n_parent else parent.link
        else:
            right_no = 0

        if left_no:
            left = self._read(left_no)
            if used(left) - cell_cost(left.ptype, left.cells[-1]) >= MIN_FILL:
                self._borrow_left(parent_no, parent, j, left_no, left, n_no, n_page,
                                  path)
                return
        if right_no:
            right = self._read(right_no)
            if used(right) - cell_cost(right.ptype, right.cells[0]) >= MIN_FILL:
                self._borrow_right(parent_no, parent, j, right_no, right, n_no,
                                   n_page, path)
                return
        if left_no:
            self._merge_left(parent_no, parent, j, left_no, self._read(left_no),
                             n_no, n_page, path)
        else:
            self._merge_right(parent_no, parent, j, right_no, self._read(right_no),
                              n_no, n_page, path)

    def _borrow_left(self, parent_no, parent, j, left_no, left, n_no, n_page,
                     path):
        if n_page.ptype == PT_INTERIOR:
            n_page.cells.insert(0, (parent.cells[j - 1][0], left.link))
            last = left.cells.pop()
            parent.cells[j - 1] = (last[0], parent.cells[j - 1][1])
            left.link = last[1]
        else:
            n_page.cells.insert(0, left.cells.pop())
            parent.cells[j - 1] = (left.cells[-1][0], parent.cells[j - 1][1])
        self._write(left_no, left)
        self._write(n_no, n_page)
        # The new separator may be longer than the old one, so the parent can
        # overflow and split like any other page (§12.5).
        self._store(parent_no, parent, path[:-1])

    def _borrow_right(self, parent_no, parent, j, right_no, right, n_no,
                      n_page, path):
        if n_page.ptype == PT_INTERIOR:
            n_page.cells.append((parent.cells[j][0], n_page.link))
            first = right.cells.pop(0)
            n_page.link = first[1]
            parent.cells[j] = (first[0], parent.cells[j][1])
        else:
            moved = right.cells.pop(0)
            n_page.cells.append(moved)
            parent.cells[j] = (moved[0], parent.cells[j][1])
        self._write(right_no, right)
        self._write(n_no, n_page)
        self._store(parent_no, parent, path[:-1])

    def _merge_left(self, parent_no, parent, j, left_no, left, n_no, n_page, path):
        if left.ptype == PT_INTERIOR:
            left.cells.append((parent.cells[j - 1][0], left.link))
        left.cells.extend(n_page.cells)
        left.link = n_page.link
        self._write(left_no, left)
        n_parent = len(parent.cells)
        del parent.cells[j - 1]
        if j == n_parent:
            parent.link = left_no
        else:
            parent.cells[j - 1] = (parent.cells[j - 1][0], left_no)
        self._write(parent_no, parent)
        self.pager.free_page(n_no)
        self._propagate(parent_no, parent, path)

    def _merge_right(self, parent_no, parent, j, right_no, right, n_no, n_page, path):
        if n_page.ptype == PT_INTERIOR:
            n_page.cells.append((parent.cells[j][0], n_page.link))
        n_page.cells.extend(right.cells)
        n_page.link = right.link
        self._write(n_no, n_page)
        n_parent = len(parent.cells)
        del parent.cells[j]
        if j + 1 == n_parent:
            parent.link = n_no
        else:
            parent.cells[j] = (parent.cells[j][0], n_no)
        self._write(parent_no, parent)
        self.pager.free_page(right_no)
        self._propagate(parent_no, parent, path)

    def _propagate(self, parent_no, parent, path):
        """A merge took a cell out of the parent (§12.5, "Propagating upward")."""
        if len(path) == 1:
            if not parent.cells:
                self.set_root(parent.link)
                self.pager.free_page(parent_no)
            return
        if used(parent) >= MIN_FILL:
            return
        self._repair(parent_no, parent, path[:-1])
