"""The database file as a sequence of pages (spec section 1.1)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .errors import FormatError

MAGIC = b"SQLite format 3\x00"

# B-tree page types.
INTERIOR_INDEX = 0x02
INTERIOR_TABLE = 0x05
LEAF_INDEX = 0x0A
LEAF_TABLE = 0x0D


@dataclass(frozen=True, slots=True)
class Page:
    """A decoded B-tree page header plus its cell pointer array."""

    start: int  #: absolute file offset of the page
    kind: int  #: one of the page-type constants
    cells: tuple[int, ...]  #: absolute file offsets of the cells, in key order
    right_child: int  #: right-most child (interior pages only, else 0)

    @property
    def is_leaf(self) -> bool:
        return self.kind in (LEAF_INDEX, LEAF_TABLE)


class Pager:
    """Random access to the pages of an in-memory database image.

    ``data`` is the whole file. Only what the readers need is parsed from the
    100-byte header: page size, reserved bytes and the page count.
    """

    def __init__(self, data: bytes) -> None:
        if len(data) < 100 or data[:16] != MAGIC:
            raise FormatError("not a SQLite 3 database")
        page_size = int.from_bytes(data[16:18], "big")
        if page_size == 1:
            page_size = 65536
        if page_size < 512 or page_size & (page_size - 1):
            raise FormatError(f"invalid page size {page_size}")
        self.data = data
        self.page_size = page_size
        self.reserved = data[20]
        #: usable size ``U`` of every page.
        self.usable = page_size - self.reserved
        self.page_count = len(data) // page_size
        # Payload-overflow thresholds (spec section 1.5).
        u = self.usable
        self.min_local = ((u - 12) * 32) // 255 - 23
        self.max_local_table = u - 35
        self.max_local_index = ((u - 12) * 64) // 255 - 23

    @classmethod
    def open(cls, path: str | Path) -> "Pager":
        return cls(Path(path).read_bytes())

    def page_offset(self, pno: int) -> int:
        """Absolute file offset of page ``pno`` (1-based)."""
        if not 1 <= pno <= self.page_count:
            raise FormatError(f"page {pno} out of range")
        return (pno - 1) * self.page_size

    def u32(self, pos: int) -> int:
        try:
            return int.from_bytes(self.data[pos : pos + 4], "big")
        except IndexError:  # pragma: no cover - slicing never raises
            raise FormatError("read past end of file") from None

    def read_page(self, pno: int) -> Page:
        """Parse the B-tree header of page ``pno``."""
        start = self.page_offset(pno)
        data = self.data
        base = start + 100 if pno == 1 else start
        kind = data[base]
        ncells = (data[base + 3] << 8) | data[base + 4]
        if kind in (INTERIOR_INDEX, INTERIOR_TABLE):
            right = self.u32(base + 8)
            ptr = base + 12
        elif kind in (LEAF_INDEX, LEAF_TABLE):
            right = 0
            ptr = base + 8
        else:
            raise FormatError(f"page {pno} is not a B-tree page (type {kind})")
        if ptr + 2 * ncells > start + self.page_size:
            raise FormatError(f"page {pno}: cell pointer array overruns page")
        cells = tuple(
            start + ((data[p] << 8) | data[p + 1]) for p in range(ptr, ptr + 2 * ncells, 2)
        )
        return Page(start, kind, cells, right)

    def read_payload(self, pos: int, size: int, max_local: int) -> bytes:
        """Read a ``size``-byte cell payload starting at ``pos``.

        Follows the overflow chain when the payload does not fit locally
        (spec section 1.5). ``max_local`` is ``X`` for the kind of page.
        """
        data = self.data
        if size <= max_local:
            return data[pos : pos + size]
        usable = self.usable
        m = self.min_local
        k = m + (size - m) % (usable - 4)
        local = k if k <= max_local else m
        out = bytearray(data[pos : pos + local])
        nxt = self.u32(pos + local)
        remaining = size - local
        chunk_size = usable - 4
        hops = 0
        while remaining > 0:
            hops += 1
            if nxt == 0 or hops > self.page_count:
                raise FormatError("corrupt overflow chain")
            off = self.page_offset(nxt)
            take = min(remaining, chunk_size)
            out += data[off + 4 : off + 4 + take]
            nxt = self.u32(off)
            remaining -= take
        return bytes(out)
