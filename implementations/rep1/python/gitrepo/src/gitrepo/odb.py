"""The object database: loose objects plus packfiles, read straight off disk."""

from __future__ import annotations

import os
import re
from bisect import bisect_left

from .errors import CorruptObjectError, GitRepoError, ObjectNotFoundError
from .packfile import Pack, PackIndex
from .inflate import zlib_decompress
from .sha1 import Sha1

OBJECT_TYPES = ("blob", "tree", "commit", "tag")
_LOOSE_DIR = re.compile(r"[0-9a-f]{2}")
_LOOSE_FILE = re.compile(r"[0-9a-f]{38}")


def hash_object(kind: str, payload: bytes) -> str:
    """Return the id of an object of type *kind* holding *payload*."""
    h = Sha1(b"%s %d\0" % (kind.encode("ascii"), len(payload)))
    h.update(payload)
    return h.hexdigest()


def _read_file(path: str) -> bytes | None:
    try:
        with open(path, "rb") as f:
            return f.read()
    except (FileNotFoundError, NotADirectoryError, IsADirectoryError):
        return None


class ObjectDatabase:
    """Reads objects from ``<git_dir>/objects``.

    The set of loose objects and the pack indexes are scanned once, when the
    database is opened.  Every object is decoded at most once; results (and
    failures) are cached for the lifetime of the instance.
    """

    def __init__(self, git_dir: str) -> None:
        self.objects_dir = os.path.join(git_dir, "objects")
        self._loose: set[str] = set()
        self._loose_sorted: list[str] = []
        self._pack_indexes: list[tuple[str, PackIndex | None, bytes | None]] = []
        self._packs: dict[int, Pack | None] = {}
        self._cache: dict[str, tuple[str, bytes] | GitRepoError] = {}
        self._verified: set[str] = set()
        self._scan_loose()
        self._scan_packs()

    # -- start-up scan -----------------------------------------------------

    def _scan_loose(self) -> None:
        try:
            with os.scandir(self.objects_dir) as top:
                dirs = [e.name for e in top if _LOOSE_DIR.fullmatch(e.name) and e.is_dir()]
        except OSError:
            return
        for d in dirs:
            try:
                with os.scandir(os.path.join(self.objects_dir, d)) as it:
                    for e in it:
                        if _LOOSE_FILE.fullmatch(e.name) and e.is_file():
                            self._loose.add(d + e.name)
            except OSError:
                continue
        self._loose_sorted = sorted(self._loose)

    def _scan_packs(self) -> None:
        pack_dir = os.path.join(self.objects_dir, "pack")
        try:
            names = sorted(os.listdir(pack_dir))
        except OSError:
            return
        stems = {n[:-5] for n in names if n.endswith(".pack")}
        for name in names:
            if not name.endswith(".idx") or name[:-4] not in stems:
                continue
            stem = os.path.join(pack_dir, name[:-4])
            raw = _read_file(stem + ".idx")
            if raw is None:
                continue
            try:
                index = PackIndex(raw)
            except CorruptObjectError:
                index = None
            self._pack_indexes.append((stem, index, raw))

    # -- statistics --------------------------------------------------------

    @property
    def loose_count(self) -> int:
        """Number of loose object files (damaged ones included)."""
        return len(self._loose)

    @property
    def pack_count(self) -> int:
        """Number of ``.idx`` files that have a matching ``.pack``."""
        return len(self._pack_indexes)

    @property
    def packed_count(self) -> int:
        """Sum of the object counts of all packs (an object in two packs counts twice)."""
        total = 0
        for _, index, raw in self._pack_indexes:
            if index is None:
                raise CorruptObjectError("unreadable pack index")
            total += index.count
        return total

    # -- presence and abbreviation ----------------------------------------

    def contains(self, oid: str) -> bool:
        """True if *oid* is a loose file or listed in a pack index."""
        if oid in self._loose:
            return True
        raw = bytes.fromhex(oid)
        return any(index is not None and index.find(raw) is not None
                   for _, index, _ in self._pack_indexes)

    def expand_prefix(self, prefix: str) -> str:
        """Expand the lowercase hex *prefix* to the unique id it abbreviates.

        Raises :class:`ObjectNotFoundError` if no object, or more than one
        object, starts with it.
        """
        found: set[str] = set()
        i = bisect_left(self._loose_sorted, prefix)
        while i < len(self._loose_sorted) and self._loose_sorted[i].startswith(prefix):
            found.add(self._loose_sorted[i])
            if len(found) > 1:
                break
            i += 1
        # Pad to whole bytes for the packed search, then filter on the half byte.
        whole = prefix[: len(prefix) & ~1]
        key = bytes.fromhex(whole)
        for _, index, _ in self._pack_indexes:
            if index is None or len(found) > 1:
                continue
            i = index.lower_bound(key)
            while i < index.count:
                oid = index.id_at(i).hex()
                if not oid.startswith(prefix):
                    if oid.startswith(whole):
                        i += 1
                        continue
                    break
                found.add(oid)
                if len(found) > 1:
                    break
                i += 1
        if len(found) != 1:
            raise ObjectNotFoundError(f"ambiguous or unknown abbreviation {prefix}")
        return next(iter(found))

    # -- reading -----------------------------------------------------------

    def _pack(self, n: int) -> Pack | None:
        if n not in self._packs:
            stem, index, _ = self._pack_indexes[n]
            data = _read_file(stem + ".pack")
            self._packs[n] = (None if index is None or data is None
                              else Pack(index, data, self.read))
        return self._packs[n]

    def read(self, oid: str) -> tuple[str, bytes]:
        """Return ``(type, payload)`` of object *oid*.

        Raises :class:`ObjectNotFoundError` if absent and
        :class:`CorruptObjectError` if damaged.  This does not verify the hash;
        see :meth:`read_verified`.
        """
        cached = self._cache.get(oid)
        if cached is None:
            try:
                cached = self._read_uncached(oid)
            except GitRepoError as exc:
                cached = exc
            except (IndexError, ValueError, OverflowError, MemoryError) as exc:
                cached = CorruptObjectError(f"damaged object {oid}: {exc}")
            self._cache[oid] = cached
        if isinstance(cached, GitRepoError):
            raise cached
        return cached

    def _read_uncached(self, oid: str) -> tuple[str, bytes]:
        if oid in self._loose:
            return self._read_loose(oid)
        raw = bytes.fromhex(oid)
        for n, (_, index, _) in enumerate(self._pack_indexes):
            if index is None:
                continue
            i = index.find(raw)
            if i is None:
                continue
            pack = self._pack(n)
            if pack is None:
                raise CorruptObjectError("unreadable packfile")
            return pack.read_at(index.offset_at(i))
        raise ObjectNotFoundError(f"object {oid} not found")

    def _read_loose(self, oid: str) -> tuple[str, bytes]:
        data = _read_file(os.path.join(self.objects_dir, oid[:2], oid[2:]))
        if data is None:
            raise ObjectNotFoundError(f"object {oid} not found")
        plain, _ = zlib_decompress(data)
        sp = plain.find(b" ", 0, 8)
        nul = plain.find(b"\0", 0, 32)
        if sp < 0 or nul < sp:
            raise CorruptObjectError("malformed loose object header")
        kind = plain[:sp].decode("ascii", "replace")
        size_text = plain[sp + 1:nul]
        if kind not in OBJECT_TYPES or not size_text.isdigit() or not size_text.isascii():
            raise CorruptObjectError("malformed loose object header")
        if len(plain) - nul - 1 != int(size_text):
            raise CorruptObjectError("loose object size mismatch")
        return kind, plain[nul + 1:]

    def read_verified(self, oid: str) -> tuple[str, bytes]:
        """Like :meth:`read`, but also check that the content hashes to *oid*."""
        kind, payload = self.read(oid)
        if oid not in self._verified:
            if hash_object(kind, payload) != oid:
                raise CorruptObjectError(f"object {oid} does not match its hash")
            self._verified.add(oid)
        return kind, payload
