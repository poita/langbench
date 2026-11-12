"""The write-ahead log: record encoding, recovery scan, size accounting (SPEC §15, §16)."""

from __future__ import annotations

import struct

from .constants import PAGE_SIZE
from .crc import crc32

_REC_HEAD = struct.Struct(">B3xQII")     # type, zero, txn_id, page_no|frame_count, payload_len
REC_HEADER_SIZE = 24
PAGE_IMAGE = 1
COMMIT = 2
LOG_HEADER_SIZE = 32
PAGE_RECORD_SIZE = REC_HEADER_SIZE + PAGE_SIZE


def _make_header() -> bytes:
    body = b"TESSWAL1" + struct.pack(">HH", 1, PAGE_SIZE) + bytes(16)
    return body + struct.pack(">I", crc32(body))


#: The constant 32-byte log header (SPEC §15.1).
LOG_HEADER = _make_header()


def encode_record(kind: int, txn_id: int, number: int, payload: bytes = b"") -> bytes:
    """One log record: 24-byte header (with CRC over header prefix + payload) and payload."""
    head = _REC_HEAD.pack(kind, txn_id, number, len(payload))
    return head + struct.pack(">I", crc32(payload, crc32(head))) + payload


def header_is_valid(data: bytes) -> bool:
    """Whether ``data`` begins with a valid log header (SPEC §16.2)."""
    return len(data) >= LOG_HEADER_SIZE and data[:LOG_HEADER_SIZE] == LOG_HEADER


class Wal:
    """The log as the engine sees it.

    ``base`` holds the bytes inherited from the input log (header plus every
    committed transaction recovery accepted). Transactions committed during
    the run are kept as page lists and only encoded, with their CRCs, when
    :meth:`to_bytes` is called: a checkpoint resets the log, so records that
    are checkpointed away never need a checksum at all.
    """

    def __init__(self, base: bytes = LOG_HEADER):
        self.base = base
        self._pending: list[tuple[int, list[tuple[int, bytes]]]] = []
        self.size = len(base)

    def append(self, txn_id: int, images: list[tuple[int, bytes]]) -> None:
        """Append one committed transaction: its page images, then the commit record."""
        self._pending.append((txn_id, images))
        self.size += PAGE_RECORD_SIZE * len(images) + REC_HEADER_SIZE

    def reset(self) -> None:
        """Empty the log down to its header."""
        self.base = LOG_HEADER
        self._pending = []
        self.size = LOG_HEADER_SIZE

    def to_bytes(self) -> bytes:
        parts = [self.base]
        for txn_id, images in self._pending:
            for page_no, payload in images:
                parts.append(encode_record(PAGE_IMAGE, txn_id, page_no, payload))
            parts.append(encode_record(COMMIT, txn_id, len(images)))
        return b"".join(parts)


def recover(data: bytes | None) -> tuple[Wal, dict[int, bytes]]:
    """Scan an input log and return the trimmed log plus the page overlay.

    Implements SPEC §16.2–§16.4: a bad header discards everything; otherwise
    every transaction whose commit record is intact is replayed, and the log
    is cut at the end of the last such commit record.
    """
    overlay: dict[int, bytes] = {}
    if data is None or not header_is_valid(data):
        return Wal(), overlay
    total = len(data)
    off = valid_end = LOG_HEADER_SIZE
    group_txn: int | None = None
    group: list[tuple[int, bytes]] = []
    unpack = _REC_HEAD.unpack_from
    while True:
        if total - off < REC_HEADER_SIZE:
            break
        kind, txn_id, number, plen = unpack(data, off)
        if kind not in (PAGE_IMAGE, COMMIT) or data[off + 1:off + 4] != b"\x00\x00\x00":
            break
        if plen != (PAGE_SIZE if kind == PAGE_IMAGE else 0) or number < 1:
            break
        if total - off < REC_HEADER_SIZE + plen:
            break
        stored = struct.unpack_from(">I", data, off + 20)[0]
        payload = data[off + REC_HEADER_SIZE:off + REC_HEADER_SIZE + plen]
        if crc32(payload, crc32(data[off:off + 20])) != stored:
            break
        if kind == PAGE_IMAGE:
            if group_txn is not None and group_txn != txn_id:
                break
            group_txn = txn_id
            group.append((number, payload))
            off += REC_HEADER_SIZE + plen
        else:
            if group_txn is None or group_txn != txn_id or len(group) != number:
                break
            for page_no, image in group:
                overlay[page_no] = image
            group_txn, group = None, []
            off += REC_HEADER_SIZE
            valid_end = off
    return Wal(bytes(data[:valid_end])), overlay
