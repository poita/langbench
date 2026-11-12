"""The pager: page reads through the log overlay, dirty pages, allocation, commit (SPEC §10, §13)."""

from __future__ import annotations

import struct

from .constants import PAGE_FREE, PAGE_SIZE, WAL_LIMIT
from .header import Header, fresh_page
from .wal import Wal, recover

ZERO_PAGE = bytes(PAGE_SIZE)
_FREE_HEAD = struct.Struct(">B3xI")


class Pager:
    """Owns the main file image, the log, the overlay and the open transaction.

    Pages are read from, in order: the open transaction's dirty pages, the
    overlay of committed log images, the main file. All engine header fields
    live in :attr:`header` (the decoded contents of page 1) and are restored
    from a snapshot when a transaction is rolled back.
    """

    def __init__(self, main: bytearray, wal: Wal, overlay: dict[int, bytes]):
        self.main = main
        self.wal = wal
        self.overlay = overlay
        self.dirty: dict[int, bytes] = {}
        self.in_txn = False
        self._snapshot: Header | None = None
        first = overlay.get(1)
        if first is None:
            first = bytes(main[:PAGE_SIZE])
        self.header = Header.decode(first)

    @classmethod
    def open(cls, main: bytes | None = None, wal: bytes | None = None) -> "Pager":
        """Open a database from the bytes of ``main.tdb`` and ``main.twal`` (SPEC §16)."""
        image = bytearray(main) if main else bytearray(fresh_page())
        log, overlay = recover(wal)
        return cls(image, log, overlay)

    # -- reading and writing pages -------------------------------------------------

    def read(self, page_no: int) -> bytes:
        page = self.dirty.get(page_no)
        if page is not None:
            return page
        page = self.overlay.get(page_no)
        if page is not None:
            return page
        off = (page_no - 1) * PAGE_SIZE
        if off + PAGE_SIZE <= len(self.main):
            return bytes(self.main[off:off + PAGE_SIZE])
        return ZERO_PAGE

    def write(self, page_no: int, data: bytes) -> None:
        """Mark a page dirty with its new image (dirty because written, not because changed)."""
        assert self.in_txn and len(data) == PAGE_SIZE
        self.dirty[page_no] = data

    def allocate(self) -> int:
        """SPEC §10 ``allocate_page``: pop the free list, else extend the file."""
        h = self.header
        if h.freelist_head:
            page_no = h.freelist_head
            h.freelist_head = _FREE_HEAD.unpack_from(self.read(page_no))[1]
            h.freelist_count -= 1
            return page_no
        h.page_count += 1
        return h.page_count

    def free(self, page_no: int) -> None:
        """SPEC §10 ``free_page``: push the page onto the free list."""
        h = self.header
        self.write(page_no, _FREE_HEAD.pack(PAGE_FREE, h.freelist_head) + bytes(PAGE_SIZE - 8))
        h.freelist_head = page_no
        h.freelist_count += 1

    # -- transactions ---------------------------------------------------------------

    def begin(self) -> None:
        self._snapshot = self.header.copy()
        self.dirty = {}
        self.in_txn = True

    def rollback(self) -> None:
        assert self.in_txn
        self.header = self._snapshot
        self._snapshot = None
        self.dirty = {}
        self.in_txn = False

    def commit(self) -> tuple[int, int]:
        """Commit the open transaction; returns ``(txn_id, frame_count)`` (SPEC §13.4)."""
        from .checkpoint import checkpoint

        assert self.in_txn
        h = self.header
        h.commit_counter += 1
        self.dirty[1] = h.encode()
        images = sorted(self.dirty.items())
        self.wal.append(h.commit_counter, images)
        self.overlay.update(self.dirty)
        self.dirty = {}
        self._snapshot = None
        self.in_txn = False
        if self.wal.size >= WAL_LIMIT:
            checkpoint(self)
        return h.commit_counter, len(images)
