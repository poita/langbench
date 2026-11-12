"""Pack index (version 2) lookup and packfile object decoding."""

from __future__ import annotations

import struct
from typing import Callable

from .delta import apply_delta
from .errors import CorruptObjectError
from .inflate import zlib_decompress

_TYPE_NAMES = {1: "commit", 2: "tree", 3: "blob", 4: "tag"}
OFS_DELTA = 6
REF_DELTA = 7


class PackIndex:
    """A parsed ``.idx`` file (version 2) supporting O(log N) lookups."""

    def __init__(self, data: bytes) -> None:
        if len(data) < 1032 or data[:8] != b"\xfftOc\x00\x00\x00\x02":
            raise CorruptObjectError("unsupported pack index")
        self.data = data
        self.fanout = struct.unpack(">256I", data[8:1032])
        self.count = self.fanout[255]
        n = self.count
        self._ids = 1032
        self._offsets = 1032 + 24 * n
        self._big = self._offsets + 4 * n
        if len(data) < self._big + 40:
            raise CorruptObjectError("truncated pack index")

    def id_at(self, i: int) -> bytes:
        """Raw id of the *i*-th object in sorted order."""
        p = self._ids + 20 * i
        return self.data[p:p + 20]

    def lower_bound(self, key: bytes) -> int:
        """Index of the first stored id that is >= *key* (20 or fewer bytes)."""
        first = key[0] if key else 0
        lo = self.fanout[first - 1] if first else 0
        hi = self.fanout[first]
        ln = len(key)
        data, base = self.data, self._ids
        while lo < hi:
            mid = (lo + hi) >> 1
            p = base + 20 * mid
            if data[p:p + ln] < key:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def find(self, raw_id: bytes) -> int | None:
        """Position of the 20-byte *raw_id*, or ``None`` when absent."""
        i = self.lower_bound(raw_id)
        if i < self.count and self.id_at(i) == raw_id:
            return i
        return None

    def offset_at(self, i: int) -> int:
        """Packfile offset of the *i*-th object."""
        p = self._offsets + 4 * i
        value = int.from_bytes(self.data[p:p + 4], "big")
        if value & 0x80000000:
            j = value & 0x7FFFFFFF
            q = self._big + 8 * j
            if q + 8 > len(self.data) - 40:
                raise CorruptObjectError("bad 64-bit offset index")
            return int.from_bytes(self.data[q:q + 8], "big")
        return value

    def prefix_matches(self, prefix: bytes, limit: int = 2) -> list[bytes]:
        """Up to *limit* raw ids that start with *prefix* (whole bytes)."""
        found: list[bytes] = []
        i = self.lower_bound(prefix)
        while i < self.count and len(found) < limit:
            raw = self.id_at(i)
            if not raw.startswith(prefix):
                break
            found.append(raw)
            i += 1
        return found


class Pack:
    """A packfile paired with its index.

    *resolve_ref* is called with a 40-digit hex id to fetch the base of a
    ``REF_DELTA`` (which may live outside this pack); it returns
    ``(type, payload)``.
    """

    def __init__(self, index: PackIndex, data: bytes,
                 resolve_ref: Callable[[str], tuple[str, bytes]]) -> None:
        self.index = index
        self.data = data
        self._resolve_ref = resolve_ref
        self._cache: dict[int, tuple[str, bytes]] = {}
        self.body = data[:-20]  # everything before the trailing pack checksum
        if len(data) < 32 or data[:4] != b"PACK" or int.from_bytes(data[4:8], "big") != 2:
            self._valid = False
        else:
            self._valid = True

    def read_at(self, offset: int) -> tuple[str, bytes]:
        """Reconstruct the object stored at *offset*: ``(type, payload)``.

        Results (including delta bases) are cached for the life of the pack.
        """
        cached = self._cache.get(offset)
        if cached is not None:
            return cached
        if not self._valid:
            raise CorruptObjectError("invalid packfile")
        result = self._read_uncached(offset)
        self._cache[offset] = result
        return result

    def _read_uncached(self, offset: int) -> tuple[str, bytes]:
        data = body = self.body
        end_limit = len(data)
        if not 12 <= offset < end_limit:
            raise CorruptObjectError("object offset outside packfile")
        pos = offset
        byte = data[pos]
        pos += 1
        kind = (byte >> 4) & 7
        size = byte & 15
        shift = 4
        while byte & 0x80:
            if pos >= end_limit:
                raise CorruptObjectError("truncated object header")
            byte = data[pos]
            pos += 1
            size |= (byte & 0x7F) << shift
            shift += 7
        if kind in _TYPE_NAMES:
            payload, _ = zlib_decompress(body, pos)
            if len(payload) != size:
                raise CorruptObjectError("packed object size mismatch")
            return _TYPE_NAMES[kind], payload
        if kind == OFS_DELTA:
            byte = data[pos]
            pos += 1
            back = byte & 0x7F
            while byte & 0x80:
                if pos >= end_limit:
                    raise CorruptObjectError("truncated delta base offset")
                byte = data[pos]
                pos += 1
                back = ((back + 1) << 7) | (byte & 0x7F)
            base_offset = offset - back
            if back <= 0 or base_offset < 12:
                raise CorruptObjectError("bad delta base offset")
            base_type, base = self.read_at(base_offset)
        elif kind == REF_DELTA:
            if pos + 20 > end_limit:
                raise CorruptObjectError("truncated delta base id")
            base_type, base = self._resolve_ref(data[pos:pos + 20].hex())
            pos += 20
        else:
            raise CorruptObjectError("invalid packed object type")
        delta, _ = zlib_decompress(body, pos)
        if len(delta) != size:
            raise CorruptObjectError("packed delta size mismatch")
        return base_type, apply_delta(base, delta)
