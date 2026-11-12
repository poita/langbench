"""The Tessera engine: documents, secondary indexes, transactions (SPEC §13, §14, §17, §18.3)."""

from __future__ import annotations

from typing import Any, Callable, NamedTuple, Union

from .btree import BTree
from .checkpoint import checkpoint as _checkpoint
from .constants import (MAX_DEPTH, MAX_DOC, MAX_INDEX_KEY, MAX_INDEXES, MAX_INLINE,
                        MAX_KEY, PAGE_INDEX_LEAF, PAGE_LEAF)
from .errors import TesseraError
from .header import IndexSlot
from .indexkey import entry_key, vkey_length
from .overflow import free_chain, read_document_bytes, write_chain
from .pager import Pager
from .parser import parse_predicate
from .query import Plan, Predicate, candidate_bounds, choose_plan, evaluate
from .value import (MISSING, depth, deserialize, normalize_path, serialize, set_path,
                    unset_path)

Key = Union[str, bytes]
Path = Union[str, "tuple[str, ...]"]


class IndexInfo(NamedTuple):
    slot: int
    path: str
    root: int
    entries: int


class Stat(NamedTuple):
    pages: int
    free: int
    freehead: int
    docs: int
    root: int
    height: int
    commits: int
    indexes: int
    wal: int


class FindResult(NamedTuple):
    plan: Plan
    rows: "list[tuple[bytes, Any]]"


def normalize_key(key: Key) -> bytes:
    """Validate a primary key (SPEC §5.1) and return it as bytes."""
    raw = key.encode("utf-8") if isinstance(key, str) else bytes(key)
    if not 1 <= len(raw) <= MAX_KEY:
        raise TesseraError("bad-key", f"{len(raw)} bytes")
    return raw


class Database:
    """A Tessera database held in memory.

    Open one with :meth:`open` (from the bytes of ``main.tdb`` / ``main.twal``)
    or :meth:`open_files`; the result of running commands is read back with
    :meth:`db_image` and :meth:`wal_image` or written with :meth:`save`.

    Writing operations (:meth:`put`, :meth:`delete`, :meth:`update`,
    :meth:`unset`, :meth:`create_index`, :meth:`drop_index`) run in an implicit
    transaction unless one was opened with :meth:`begin`. Every failure raises
    :class:`~tessera.errors.TesseraError` and leaves the database unchanged.

    Keys may be given as ``str`` or ``bytes`` and are returned as ``bytes``.
    """

    def __init__(self, pager: Pager):
        self._pager = pager

    # -- opening and saving --------------------------------------------------------------

    @classmethod
    def open(cls, db: bytes | None = None, wal: bytes | None = None) -> "Database":
        """Open a database from file contents, replaying committed log transactions.

        ``db=None`` (or empty) means a fresh database; a missing or damaged log
        is discarded, and a log with an incomplete tail is trimmed (SPEC §16).
        """
        return cls(Pager.open(db, wal))

    @classmethod
    def open_files(cls, db_path: str, wal_path: str | None = None) -> "Database":
        """Open ``db_path`` and its log (default: ``db_path`` with a ``.twal`` extension).

        Either file may be absent.
        """
        import os

        if wal_path is None:
            root, _ = os.path.splitext(db_path)
            wal_path = root + ".twal"

        def read(p: str) -> bytes | None:
            if not os.path.exists(p):
                return None
            with open(p, "rb") as f:
                return f.read()
        return cls.open(read(db_path), read(wal_path))

    def db_image(self) -> bytes:
        """The bytes of ``main.tdb`` as they would be written now."""
        return bytes(self._pager.main)

    def wal_image(self) -> bytes:
        """The bytes of ``main.twal`` as they would be written now."""
        return self._pager.wal.to_bytes()

    def save(self, db_path: str, wal_path: str) -> None:
        """Write the main file and the log to disk."""
        with open(db_path, "wb") as f:
            f.write(self.db_image())
        with open(wal_path, "wb") as f:
            f.write(self.wal_image())

    # -- transactions --------------------------------------------------------------------

    @property
    def in_transaction(self) -> bool:
        return self._pager.in_txn

    def begin(self) -> None:
        """Open an explicit transaction."""
        if self._pager.in_txn:
            raise TesseraError("txn-active")
        self._pager.begin()

    def commit(self) -> tuple[int, int]:
        """Commit the explicit transaction; returns ``(txn_id, page frames written)``."""
        if not self._pager.in_txn:
            raise TesseraError("no-txn")
        return self._pager.commit()

    def rollback(self) -> None:
        """Discard the explicit transaction."""
        if not self._pager.in_txn:
            raise TesseraError("no-txn")
        self._pager.rollback()

    def checkpoint(self) -> int:
        """Copy the log into the main file; returns the number of pages copied."""
        if self._pager.in_txn:
            raise TesseraError("txn-active")
        return _checkpoint(self._pager)

    def _write(self, fn: Callable[[], Any]) -> Any:
        """Run ``fn`` in the open transaction, or in an implicit one."""
        pager = self._pager
        if pager.in_txn:
            return fn()
        pager.begin()
        try:
            result = fn()
        except BaseException:
            pager.rollback()
            raise
        pager.commit()
        return result

    # -- trees ---------------------------------------------------------------------------

    def _primary(self) -> BTree:
        h = self._pager

        def set_root(r: int) -> None:
            h.header.primary_root = r
        return BTree(h, PAGE_LEAF, lambda: h.header.primary_root, set_root)

    def _index_tree(self, slot_no: int) -> BTree:
        pager = self._pager

        def set_root(r: int) -> None:
            pager.header.slots[slot_no].root = r
        return BTree(pager, PAGE_INDEX_LEAF, lambda: pager.header.slots[slot_no].root, set_root)

    def _live_slots(self) -> list[tuple[int, IndexSlot]]:
        return [(s, slot) for s, slot in enumerate(self._pager.header.slots) if slot is not None]

    def _read_doc(self, cell: tuple[int, int, bytes]) -> Any:
        doc_len, overflow, inline = cell
        return deserialize(read_document_bytes(self._pager, doc_len, overflow, inline))

    # -- documents -----------------------------------------------------------------------

    def get(self, key: Key) -> Any:
        """The document stored under ``key``; raises ``not-found``."""
        cell = self._primary().get(normalize_key(key))
        if cell is None:
            raise TesseraError("not-found")
        return self._read_doc(cell)

    def __contains__(self, key: Key) -> bool:
        return self._primary().get(normalize_key(key)) is not None

    def __len__(self) -> int:
        return self._pager.header.primary_count

    def put(self, key: Key, doc: Any) -> bool:
        """Store a document; returns True if the key was new, False if it replaced one."""
        key = normalize_key(key)
        data = self._serialize(doc)
        self._check_index_keys(key, doc)
        cell = self._primary().get(key)
        old = self._read_doc(cell) if cell is not None and self._live_slots() else MISSING
        return self._write(lambda: self._store(key, cell, old, doc, data))

    def update(self, key: Key, path: Path, value: Any) -> None:
        """Set the field at ``path`` of a document, creating missing intermediate objects."""
        key = normalize_key(key)
        segs = normalize_path(path)
        cell = self._primary().get(key)
        if cell is None:
            raise TesseraError("not-found")
        old = self._read_doc(cell)
        new = set_path(old, segs, value)
        data = self._serialize(new)
        self._check_index_keys(key, new)
        self._write(lambda: self._store(key, cell, old, new, data))

    def unset(self, key: Key, path: Path) -> None:
        """Remove the field at ``path`` of a document."""
        key = normalize_key(key)
        segs = normalize_path(path)
        cell = self._primary().get(key)
        if cell is None:
            raise TesseraError("not-found")
        old = self._read_doc(cell)
        new = unset_path(old, segs)
        data = serialize(new)
        self._write(lambda: self._store(key, cell, old, new, data))

    def delete(self, key: Key) -> None:
        """Remove a document; raises ``not-found``."""
        key = normalize_key(key)
        tree = self._primary()
        cell = tree.get(key)
        if cell is None:
            raise TesseraError("not-found")
        old = self._read_doc(cell) if self._live_slots() else MISSING

        def work() -> None:
            if cell[1]:
                free_chain(self._pager, cell[1])
            tree.delete(key)
            self._pager.header.primary_count -= 1
            self._maintain_indexes(key, old, MISSING)
        self._write(work)

    def _serialize(self, doc: Any) -> bytes:
        if depth(doc) > MAX_DEPTH:
            raise TesseraError("depth")
        data = serialize(doc)
        if len(data) > MAX_DOC:
            raise TesseraError("doc-too-large", f"{len(data)} bytes")
        return data

    def _check_index_keys(self, key: bytes, doc: Any) -> None:
        for _, slot in self._live_slots():
            ik = entry_key(doc, slot.segs, key)
            if ik is not None and len(ik) > MAX_INDEX_KEY:
                raise TesseraError("index-key-too-long", slot.path)

    def _store(self, key: bytes, cell: Any, old: Any, new: Any, data: bytes) -> bool:
        """SPEC §14.3 for put / update / unset: primary tree first, then the indexes."""
        pager = self._pager
        if cell is not None and cell[1]:
            free_chain(pager, cell[1])
        inline, rest = data[:MAX_INLINE], data[MAX_INLINE:]
        cell_new = (len(data), write_chain(pager, rest), inline)
        self._primary().insert(key, cell_new)
        if cell is None:
            pager.header.primary_count += 1
        self._maintain_indexes(key, old, new)
        return cell is None

    def _maintain_indexes(self, key: bytes, old: Any, new: Any) -> None:
        for s, slot in self._live_slots():
            o = None if old is MISSING else entry_key(old, slot.segs, key)
            w = None if new is MISSING else entry_key(new, slot.segs, key)
            if o == w:
                continue
            tree = self._index_tree(s)
            if o is not None:
                tree.delete(o)
                slot.entries -= 1
            if w is not None:
                tree.insert(w, None)
                slot.entries += 1

    # -- scanning and querying -------------------------------------------------------------

    def scan(self, start: Key | None = None, stop: Key | None = None, limit: int | None = None,
             reverse: bool = False, keys_only: bool = False) -> list:
        """Documents with ``start <= key < stop`` in key order (descending if ``reverse``).

        Returns ``[(key, document), ...]``, or just the keys with ``keys_only``.
        ``limit`` is applied after ordering. Bounds are not subject to key rules.
        """
        lo = start.encode("utf-8") if isinstance(start, str) else start
        hi = stop.encode("utf-8") if isinstance(stop, str) else stop
        out: list = []
        if limit == 0:
            return out
        tree = self._primary()
        it = tree.iter_reverse(hi) if reverse else tree.iter_from(lo)
        for key, cell in it:
            if reverse:
                if lo is not None and key < lo:
                    break
            elif hi is not None and key >= hi:
                break
            out.append(key if keys_only else (key, self._read_doc(cell)))
            if limit is not None and len(out) >= limit:
                break
        return out

    def plan(self, pred: Predicate | str) -> Plan:
        """The plan ``find`` would use for a predicate (SPEC §17.3)."""
        if isinstance(pred, str):
            pred = parse_predicate(pred)
        return choose_plan(pred, [s.path for _, s in self._live_slots()])

    def find(self, pred: Predicate | str, limit: int | None = None) -> FindResult:
        """Documents matching a predicate, in ascending key order, with the plan used.

        ``pred`` is a predicate AST (:mod:`tessera.query`) or text in the command
        language, e.g. ``'age >= 30 and name == "ada"'``.
        """
        if isinstance(pred, str):
            pred = parse_predicate(pred)
        plan = choose_plan(pred, [s.path for _, s in self._live_slots()])
        rows: list = []
        if limit == 0:
            return FindResult(plan, rows)
        tree = self._primary()
        if plan.kind == "scan":
            for key, cell in tree.iter_from(None):
                doc = self._read_doc(cell)
                if evaluate(pred, doc):
                    rows.append((key, doc))
                    if limit is not None and len(rows) >= limit:
                        break
            return FindResult(plan, rows)
        slot_no = next(s for s, slot in self._live_slots() if slot.path == plan.path)
        lower, accept = candidate_bounds(plan)
        candidates = []
        for ik, _ in self._index_tree(slot_no).iter_from(lower):
            verdict = accept(ik)
            if verdict is None:
                break
            if verdict:
                candidates.append(ik[vkey_length(ik):])
        candidates.sort()
        for key in candidates:
            doc = self._read_doc(tree.get(key))
            if evaluate(pred, doc):
                rows.append((key, doc))
                if limit is not None and len(rows) >= limit:
                    break
        return FindResult(plan, rows)

    # -- indexes -------------------------------------------------------------------------

    def create_index(self, path: Path) -> int:
        """Build a secondary index on ``path``; returns its number of entries (SPEC §14.4)."""
        segs = normalize_path(path)
        text = ".".join(segs)
        header = self._pager.header
        if any(slot.path == text for _, slot in self._live_slots()):
            raise TesseraError("index-exists", text)
        if header.index_count >= MAX_INDEXES:
            raise TesseraError("index-limit")
        entries = []
        for key, cell in self._primary().iter_from(None):
            ik = entry_key(self._read_doc(cell), segs, key)
            if ik is not None:
                if len(ik) > MAX_INDEX_KEY:
                    raise TesseraError("index-key-too-long", text)
                entries.append(ik)

        def work() -> int:
            s = header.slots.index(None)
            header.slots[s] = slot = IndexSlot(text)
            tree = self._index_tree(s)
            for ik in entries:                 # primary-key order, not index-key order
                tree.insert(ik, None)
                slot.entries += 1
            return slot.entries
        return self._write(work)

    def drop_index(self, path: Path) -> int:
        """Remove the index on ``path``; returns the number of pages freed (SPEC §14.5)."""
        text = ".".join(normalize_path(path))
        for s, slot in self._live_slots():
            if slot.path == text:
                break
        else:
            raise TesseraError("index-missing", text)

        def work() -> int:
            pages = self._index_tree(s).pages_post_order()
            for p in pages:
                self._pager.free(p)
            self._pager.header.slots[s] = None
            return len(pages)
        return self._write(work)

    def indexes(self) -> list[IndexInfo]:
        """The live indexes in slot order."""
        return [IndexInfo(s, slot.path, slot.root, slot.entries) for s, slot in self._live_slots()]

    def stat(self) -> Stat:
        """Counters of the engine's current view (including an open transaction)."""
        h = self._pager.header
        return Stat(h.page_count, h.freelist_count, h.freelist_head, h.primary_count,
                    h.primary_root, self._primary().height(), h.commit_counter,
                    h.index_count, self._pager.wal.size)
