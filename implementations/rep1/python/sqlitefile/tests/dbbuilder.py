"""A tiny SQLite file writer used to build fixtures for the tests.

It is deliberately independent of the library under test: it only knows how to
*write* the formats (varints, records, B-tree pages, overflow chains).
"""

from __future__ import annotations

import struct


def varint(n: int) -> bytes:
    n &= (1 << 64) - 1
    if n < 1 << 56:
        out = [n & 0x7F]
        n >>= 7
        while n:
            out.append((n & 0x7F) | 0x80)
            n >>= 7
        return bytes(reversed(out))
    low, high = n & 0xFF, n >> 8
    out = [low]
    for _ in range(8):
        out.append((high & 0x7F) | 0x80)
        high >>= 7
    return bytes(reversed(out))


def record(values) -> bytes:
    types, body = [], b""
    for v in values:
        if v is None:
            types.append(0)
        elif isinstance(v, bool):
            raise TypeError
        elif isinstance(v, int):
            if v == 0:
                types.append(8)
            elif v == 1:
                types.append(9)
            else:
                for t, size in ((1, 1), (2, 2), (3, 3), (4, 4), (5, 6), (6, 8)):
                    if -(1 << (8 * size - 1)) <= v < 1 << (8 * size - 1):
                        types.append(t)
                        body += v.to_bytes(size, "big", signed=True)
                        break
        elif isinstance(v, float):
            types.append(7)
            body += struct.pack(">d", v)
        elif isinstance(v, str):
            raw = v.encode()
            types.append(13 + 2 * len(raw))
            body += raw
        else:
            types.append(12 + 2 * len(v))
            body += bytes(v)
    header = b"".join(varint(t) for t in types)
    size = len(header) + 1
    return varint(size) + header + body


class DbBuilder:
    def __init__(self, page_size: int = 4096) -> None:
        self.page_size = page_size
        self.pages: list[bytes | None] = [None]  # page 1 is filled by build()
        self.schema: list[tuple] = []  # (type, name, tbl_name, rootpage, sql)

    # -- page helpers --------------------------------------------------------

    def _add(self, page: bytes) -> int:
        assert len(page) == self.page_size
        self.pages.append(page)
        return len(self.pages)

    def _btree_page(self, kind: int, cells: list[bytes], right: int = 0, base: int = 0) -> bytes:
        ps = self.page_size
        header = bytes([kind, 0, 0]) + struct.pack(">H", len(cells))
        interior = kind in (0x02, 0x05)
        hlen = 12 if interior else 8
        buf = bytearray(ps)
        top = ps
        ptrs = []
        for c in cells:
            top -= len(c)
            buf[top : top + len(c)] = c
            ptrs.append(top)
        ptr_end = base + hlen + 2 * len(cells)
        assert ptr_end <= top, "page overflow in test builder"
        buf[base : base + 5] = header
        buf[base + 5 : base + 7] = struct.pack(">H", top % 65536)
        if interior:
            buf[base + 8 : base + 12] = struct.pack(">I", right)
        for i, p in enumerate(ptrs):
            buf[base + hlen + 2 * i : base + hlen + 2 * i + 2] = struct.pack(">H", p)
        return bytes(buf)

    def _payload_cell(self, prefix: bytes, payload: bytes, max_local: int) -> bytes:
        u = self.page_size
        size = len(payload)
        if size <= max_local:
            return prefix + payload
        m = ((u - 12) * 32) // 255 - 23
        k = m + (size - m) % (u - 4)
        local = k if k <= max_local else m
        rest = payload[local:]
        chunk = u - 4
        pieces = [rest[i : i + chunk] for i in range(0, len(rest), chunk)]
        first = len(self.pages) + 1
        for i, piece in enumerate(pieces):
            nxt = first + i + 1 if i + 1 < len(pieces) else 0
            self._add((struct.pack(">I", nxt) + piece).ljust(u, b"\0"))
        return prefix + payload[:local] + struct.pack(">I", first)

    # -- trees -----------------------------------------------------------------

    def table_btree(self, rows, fanout: int = 4) -> int:
        """Build a table B-tree from ``(rowid, values)`` rows; return its root page."""
        x = self.page_size - 35
        leaves: list[tuple[int, int]] = []  # (page number, max rowid)
        encoded = []
        for rowid, values in rows:
            payload = record(values)
            prefix = varint(len(payload)) + varint(rowid)
            encoded.append((rowid, self._payload_cell(prefix, payload, x)))
        groups: list[list[tuple[int, bytes]]] = [[]]
        used = 0
        for item in encoded:
            need = len(item[1]) + 2
            if groups[-1] and (used + need > self.page_size - 8 or len(groups[-1]) >= 8):
                groups.append([])
                used = 0
            groups[-1].append(item)
            used += need
        for group in groups:
            pno = self._add(self._btree_page(0x0D, [c for _, c in group]))
            leaves.append((pno, group[-1][0] if group else 0))
        level = leaves
        while len(level) > 1:
            parents = []
            for i in range(0, len(level), fanout):
                group = level[i : i + fanout]
                cells = [struct.pack(">I", p) + varint(k) for p, k in group[:-1]]
                pno = self._add(self._btree_page(0x05, cells, right=group[-1][0]))
                parents.append((pno, group[-1][1]))
            level = parents
        return level[0][0]

    def index_btree(self, entries, per_leaf: int = 3) -> int:
        """Build an index B-tree from sorted entry value lists (two levels at most)."""
        u = self.page_size
        x = ((u - 12) * 64) // 255 - 23

        def leaf_cell(e):
            payload = record(e)
            return self._payload_cell(varint(len(payload)), payload, x)

        if len(entries) <= per_leaf:
            return self._add(self._btree_page(0x0A, [leaf_cell(e) for e in entries]))
        groups, promoted = [], []
        i = 0
        while i < len(entries):
            groups.append(entries[i : i + per_leaf])
            i += per_leaf
            if i < len(entries):
                promoted.append(entries[i])
                i += 1
        leaf_pages = [self._add(self._btree_page(0x0A, [leaf_cell(e) for e in g])) for g in groups]
        cells = []
        for child, e in zip(leaf_pages, promoted):
            payload = record(e)
            cells.append(
                self._payload_cell(struct.pack(">I", child) + varint(len(payload)), payload, x)
            )
        return self._add(self._btree_page(0x02, cells, right=leaf_pages[len(promoted)]))

    # -- schema ------------------------------------------------------------------

    def add_table(self, name: str, sql: str, rows) -> int:
        root = self.table_btree(rows)
        self.schema.append(("table", name, name, root, sql))
        return root

    def add_index(self, name: str, table: str, sql: str | None, entries) -> int:
        root = self.index_btree(entries)
        self.schema.append(("index", name, table, root, sql))
        return root

    def add_schema_only(self, type_: str, name: str, tbl: str, sql: str) -> None:
        self.schema.append((type_, name, tbl, 0, sql))

    def build(self) -> bytes:
        cells = []
        for i, row in enumerate(self.schema, 1):
            payload = record(list(row))
            cells.append(varint(len(payload)) + varint(i) + payload)
        page1 = bytearray(self._btree_page(0x0D, cells, base=100))
        ps = self.page_size
        header = bytearray(100)
        header[:16] = b"SQLite format 3\0"
        header[16:18] = struct.pack(">H", 1 if ps == 65536 else ps)
        header[18:20] = b"\x01\x01"
        header[21:24] = b"\x40\x20\x20"
        header[28:32] = struct.pack(">I", len(self.pages))
        header[44:48] = struct.pack(">I", 4)
        header[56:60] = struct.pack(">I", 1)
        page1[:100] = header
        self.pages[0] = bytes(page1)
        return b"".join(self.pages)  # type: ignore[arg-type]
