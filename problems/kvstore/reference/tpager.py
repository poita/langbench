"""Pages, the header page, the free list, the write-ahead log, transactions,
recovery and checkpointing: SPEC.md §7, §8, §10, §13, §15, §16.
"""

from tcrc import crc32

PAGE_SIZE = 1024
MAX_INDEXES = 16
WAL_LIMIT = 262144

DB_MAGIC = b"TESSERA1"
WAL_MAGIC = b"TESSWAL1"

PT_FREE = 0
PT_LEAF = 1
PT_INTERIOR = 2
PT_OVERFLOW = 3
PT_INDEX_LEAF = 5

ZERO_PAGE = bytes(PAGE_SIZE)

REC_PAGE = 1
REC_COMMIT = 2
REC_HEADER_LEN = 24
PAGE_REC_LEN = REC_HEADER_LEN + PAGE_SIZE


def wal_header():
    """The 32 constant bytes of §15.1."""
    h = bytearray(32)
    h[0:8] = WAL_MAGIC
    h[8:10] = (1).to_bytes(2, "big")
    h[10:12] = PAGE_SIZE.to_bytes(2, "big")
    h[28:32] = crc32(bytes(h[0:28])).to_bytes(4, "big")
    return bytes(h)


WAL_HEADER = wal_header()


class Slot(object):
    """One 48-byte index directory slot (§8)."""

    __slots__ = ("live", "path", "root", "entries")

    def __init__(self, live=0, path=b"", root=0, entries=0):
        self.live = live
        self.path = path
        self.root = root
        self.entries = entries

    def copy(self):
        return Slot(self.live, self.path, self.root, self.entries)


class Header(object):
    """The decoded contents of page 1 (§7.2)."""

    __slots__ = ("page_count", "freelist_head", "freelist_count", "primary_root",
                 "primary_count", "commit_counter", "index_count", "slots")

    def __init__(self):
        self.page_count = 1
        self.freelist_head = 0
        self.freelist_count = 0
        self.primary_root = 0
        self.primary_count = 0
        self.commit_counter = 0
        self.index_count = 0
        self.slots = [Slot() for _ in range(MAX_INDEXES)]

    def copy(self):
        h = Header()
        h.page_count = self.page_count
        h.freelist_head = self.freelist_head
        h.freelist_count = self.freelist_count
        h.primary_root = self.primary_root
        h.primary_count = self.primary_count
        h.commit_counter = self.commit_counter
        h.index_count = self.index_count
        h.slots = [s.copy() for s in self.slots]
        return h

    def encode(self):
        p = bytearray(PAGE_SIZE)
        p[0:8] = DB_MAGIC
        p[8:10] = (1).to_bytes(2, "big")
        p[10:12] = PAGE_SIZE.to_bytes(2, "big")
        p[12:16] = self.page_count.to_bytes(4, "big")
        p[16:20] = self.freelist_head.to_bytes(4, "big")
        p[20:24] = self.freelist_count.to_bytes(4, "big")
        p[24:28] = self.primary_root.to_bytes(4, "big")
        p[28:32] = self.primary_count.to_bytes(4, "big")
        p[32:40] = self.commit_counter.to_bytes(8, "big")
        p[40:44] = self.index_count.to_bytes(4, "big")
        for i, s in enumerate(self.slots):
            off = 128 + 48 * i
            if not s.live:
                continue
            p[off] = 1
            p[off + 1] = len(s.path)
            p[off + 2:off + 2 + len(s.path)] = s.path
            p[off + 32:off + 36] = s.root.to_bytes(4, "big")
            p[off + 36:off + 40] = s.entries.to_bytes(4, "big")
        return bytes(p)

    @staticmethod
    def decode(page):
        h = Header()
        h.page_count = int.from_bytes(page[12:16], "big")
        h.freelist_head = int.from_bytes(page[16:20], "big")
        h.freelist_count = int.from_bytes(page[20:24], "big")
        h.primary_root = int.from_bytes(page[24:28], "big")
        h.primary_count = int.from_bytes(page[28:32], "big")
        h.commit_counter = int.from_bytes(page[32:40], "big")
        h.index_count = int.from_bytes(page[40:44], "big")
        for i in range(MAX_INDEXES):
            off = 128 + 48 * i
            s = h.slots[i]
            s.live = page[off]
            if s.live:
                ln = page[off + 1]
                s.path = bytes(page[off + 2:off + 2 + ln])
                s.root = int.from_bytes(page[off + 32:off + 36], "big")
                s.entries = int.from_bytes(page[off + 36:off + 40], "big")
        return h


def fresh_main():
    """The one-page database of §7.3."""
    return bytearray(Header().encode())


def free_page_image(nxt):
    """A free page whose successor is `nxt` (§10)."""
    p = bytearray(PAGE_SIZE)
    p[4:8] = nxt.to_bytes(4, "big")
    return bytes(p)


class Pager(object):
    """Owns the main file image, the log, the overlay and the dirty set."""

    def __init__(self):
        self.main = fresh_main()
        self.overlay = {}
        self.wal = bytearray(WAL_HEADER)
        self.dirty = {}
        self.txn_open = False
        self.explicit = False
        self.hdr = Header()
        self.hdr_dirty = False

    # ---- opening ---------------------------------------------------------

    def open(self, main_bytes, wal_bytes):
        if main_bytes:
            self.main = bytearray(main_bytes)
        else:
            self.main = fresh_main()
        if wal_bytes is None:
            self.wal = bytearray(WAL_HEADER)
            self.overlay = {}
        else:
            self.recover(wal_bytes)
        self.hdr = Header.decode(self.read_page(1))

    def recover(self, log):
        """§16.2–§16.4: validate the header, replay committed groups, trim."""
        if not self._valid_log_header(log):
            self.wal = bytearray(WAL_HEADER)
            self.overlay = {}
            return
        overlay = {}
        valid_end = 32
        off = 32
        total = len(log)
        group_txn = None
        group = []
        while True:
            rem = total - off
            if rem < REC_HEADER_LEN:
                break
            hdr = log[off:off + REC_HEADER_LEN]
            rtype = hdr[0]
            if rtype != REC_PAGE and rtype != REC_COMMIT:
                break
            if hdr[1] or hdr[2] or hdr[3]:
                break
            txn_id = int.from_bytes(hdr[4:12], "big")
            field = int.from_bytes(hdr[12:16], "big")
            payload_len = int.from_bytes(hdr[16:20], "big")
            stored = int.from_bytes(hdr[20:24], "big")
            want = PAGE_SIZE if rtype == REC_PAGE else 0
            if payload_len != want:
                break
            if field < 1:
                break
            if rem < REC_HEADER_LEN + payload_len:
                break
            body = log[off:off + 20] + log[off + REC_HEADER_LEN:off + REC_HEADER_LEN + payload_len]
            if crc32(body) != stored:
                break
            if rtype == REC_PAGE:
                if group_txn is None:
                    group_txn = txn_id
                elif group_txn != txn_id:
                    break
                group.append((field, bytes(log[off + REC_HEADER_LEN:off + REC_HEADER_LEN + PAGE_SIZE])))
                off += PAGE_REC_LEN
            else:
                if group_txn is None or group_txn != txn_id or len(group) != field:
                    break
                for pno, image in group:
                    overlay[pno] = image
                group_txn = None
                group = []
                off += REC_HEADER_LEN
                valid_end = off
        self.overlay = overlay
        self.wal = bytearray(log[:valid_end])

    @staticmethod
    def _valid_log_header(log):
        if len(log) < 32:
            return False
        if bytes(log[0:8]) != WAL_MAGIC:
            return False
        if int.from_bytes(log[8:10], "big") != 1:
            return False
        if int.from_bytes(log[10:12], "big") != PAGE_SIZE:
            return False
        if any(log[12:28]):
            return False
        return int.from_bytes(log[28:32], "big") == crc32(bytes(log[0:28]))

    # ---- page access (§13.1, §13.2) --------------------------------------

    def read_page(self, p):
        if p == 1 and self.hdr_dirty:
            self.dirty[1] = self.hdr.encode()
            self.hdr_dirty = False
        image = self.dirty.get(p)
        if image is not None:
            return image
        image = self.overlay.get(p)
        if image is not None:
            return image
        off = (p - 1) * PAGE_SIZE
        if off + PAGE_SIZE <= len(self.main):
            return bytes(self.main[off:off + PAGE_SIZE])
        return ZERO_PAGE

    def write_page(self, p, image):
        if len(image) != PAGE_SIZE:
            raise AssertionError("page image of %d bytes" % len(image))
        self.dirty[p] = bytes(image)

    def touch_header(self):
        self.hdr_dirty = True

    # ---- allocation (§10) ------------------------------------------------

    def allocate_page(self):
        h = self.hdr
        if h.freelist_head:
            p = h.freelist_head
            image = self.read_page(p)
            h.freelist_head = int.from_bytes(image[4:8], "big")
            h.freelist_count -= 1
            self.touch_header()
            return p
        h.page_count += 1
        self.touch_header()
        return h.page_count

    def free_page(self, p):
        h = self.hdr
        self.write_page(p, free_page_image(h.freelist_head))
        h.freelist_head = p
        h.freelist_count += 1
        self.touch_header()

    # ---- transactions (§13.3, §13.4) -------------------------------------

    def begin(self, explicit):
        self.txn_open = True
        self.explicit = explicit

    def snapshot(self):
        """A failing command changes nothing (§13.3), so every write command
        runs between a snapshot and either a commit or this restore."""
        return (dict(self.dirty), self.hdr.copy(), self.hdr_dirty,
                self.txn_open, self.explicit)

    def restore(self, snap):
        self.dirty = snap[0]
        self.hdr = snap[1]
        self.hdr_dirty = snap[2]
        self.txn_open = snap[3]
        self.explicit = snap[4]

    def commit(self):
        """Append the transaction to the log; return (txn_id, frame_count)."""
        self.hdr.commit_counter += 1
        self.touch_header()
        self.read_page(1)  # materialises page 1 into the dirty set
        txn_id = self.hdr.commit_counter
        pages = sorted(self.dirty)
        out = self.wal
        for pno in pages:
            image = self.dirty[pno]
            rec = bytearray(REC_HEADER_LEN)
            rec[0] = REC_PAGE
            rec[4:12] = txn_id.to_bytes(8, "big")
            rec[12:16] = pno.to_bytes(4, "big")
            rec[16:20] = PAGE_SIZE.to_bytes(4, "big")
            rec[20:24] = crc32(bytes(rec[0:20]) + image).to_bytes(4, "big")
            out += rec
            out += image
        rec = bytearray(REC_HEADER_LEN)
        rec[0] = REC_COMMIT
        rec[4:12] = txn_id.to_bytes(8, "big")
        rec[12:16] = len(pages).to_bytes(4, "big")
        rec[20:24] = crc32(bytes(rec[0:20])).to_bytes(4, "big")
        out += rec
        for pno in pages:
            self.overlay[pno] = self.dirty[pno]
        self.dirty = {}
        self.txn_open = False
        self.explicit = False
        if len(self.wal) >= WAL_LIMIT:
            self.checkpoint()
        return txn_id, len(pages)

    def rollback(self):
        self.dirty = {}
        self.hdr_dirty = False
        self.txn_open = False
        self.explicit = False
        self.hdr = Header.decode(self.read_page(1))

    # ---- checkpointing (§15.6) -------------------------------------------

    def checkpoint(self):
        n = len(self.overlay)
        want = self.hdr.page_count * PAGE_SIZE
        if self.overlay:
            # Every overlay page is <= page_count (SPEC 15.6); taking the
            # maximum keeps a hand-built log from writing past the file.
            want = max(want, max(self.overlay) * PAGE_SIZE)
        if len(self.main) < want:
            self.main.extend(bytes(want - len(self.main)))
        for pno in sorted(self.overlay):
            off = (pno - 1) * PAGE_SIZE
            self.main[off:off + PAGE_SIZE] = self.overlay[pno]
        self.overlay = {}
        self.wal = bytearray(WAL_HEADER)
        return n

    def wal_size(self):
        return len(self.wal)
