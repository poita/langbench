"""The store: documents, secondary indexes, queries and transactions.

Implements SPEC.md §12.2 (through tbtree), §13, §14, §15.6, §17 and the
per-command execution checks of §18.3.
"""

import tvalue as V
from tvalue import (NULL, BOOL, INT, STR, LIST, OBJ, MAX_DOC, MAX_INDEX_KEY,
                    PathNotObject, PathNoField)
from tpager import Pager, PT_LEAF, PT_INDEX_LEAF, MAX_INDEXES
from tbtree import (Tree, MAX_INLINE, write_overflow_chain, free_overflow_chain,
                    read_overflow_chain)


class TessError(Exception):
    """One of the eighteen error kinds of SPEC.md §18.1."""

    def __init__(self, kind):
        Exception.__init__(self, kind)
        self.kind = kind


class Store(object):
    def __init__(self):
        self.pager = Pager()
        self.primary = Tree(self.pager, PT_LEAF, self._get_primary_root,
                            self._set_primary_root)

    # ---- opening ---------------------------------------------------------

    def open(self, main_bytes, wal_bytes):
        self.pager.open(main_bytes, wal_bytes)

    def _get_primary_root(self):
        return self.pager.hdr.primary_root

    def _set_primary_root(self, r):
        self.pager.hdr.primary_root = r
        self.pager.touch_header()

    def _index_tree(self, slot):
        pager = self.pager

        def get_root():
            return pager.hdr.slots[slot].root

        def set_root(r):
            pager.hdr.slots[slot].root = r
            pager.touch_header()

        return Tree(pager, PT_INDEX_LEAF, get_root, set_root)

    def live_slots(self):
        """Live directory slot numbers in ascending slot order (§8)."""
        return [i for i, s in enumerate(self.pager.hdr.slots) if s.live]

    # ---- transactions (§13.3) --------------------------------------------

    def begin(self):
        if self.pager.txn_open:
            raise TessError("txn-active")
        self.pager.begin(True)

    def commit(self):
        if not self.pager.txn_open:
            raise TessError("no-txn")
        return self.pager.commit()

    def rollback(self):
        if not self.pager.txn_open:
            raise TessError("no-txn")
        self.pager.rollback()

    def checkpoint(self):
        if self.pager.txn_open:
            raise TessError("txn-active")
        return self.pager.checkpoint()

    def end_of_script(self):
        if self.pager.txn_open:
            self.pager.rollback()

    def _write(self, fn):
        """Run a writing command, committing an implicit transaction around it
        and undoing everything if it fails (§13.3)."""
        pager = self.pager
        implicit = not pager.txn_open
        snap = pager.snapshot()
        if implicit:
            pager.begin(False)
        try:
            result = fn()
        except TessError:
            pager.restore(snap)
            raise
        if implicit:
            pager.commit()
        return result

    # ---- documents -------------------------------------------------------

    def _read_doc(self, cell):
        key, doc_len, overflow, inline = cell
        if overflow == 0:
            return V.deser(inline)
        tail = read_overflow_chain(self.pager, overflow, doc_len - len(inline))
        return V.deser(inline + tail)

    def _build_cell(self, key, docbytes):
        """Build a primary leaf cell, allocating the overflow chain first (§14.3)."""
        if len(docbytes) <= MAX_INLINE:
            return (key, len(docbytes), 0, docbytes)
        first = write_overflow_chain(self.pager, docbytes[MAX_INLINE:])
        return (key, len(docbytes), first, docbytes[:MAX_INLINE])

    def get(self, key):
        _p, cell = self.primary.find(key)
        if cell is None:
            raise TessError("not-found")
        return self._read_doc(cell)

    def _entry_key(self, segs, key, doc):
        """The index entry for a document, or None when it is not indexable."""
        v = V.path_resolve(doc, segs)
        if v is None:
            return None
        vk = V.vkey(v)
        if vk is None:
            return None
        return vk + key

    @staticmethod
    def _segs(path_text):
        return path_text.split(b".")

    def _check_index_keys(self, key, doc):
        for slot in self.live_slots():
            segs = self._segs(self.pager.hdr.slots[slot].path)
            entry = self._entry_key(segs, key, doc)
            if entry is not None and len(entry) > MAX_INDEX_KEY:
                raise TessError("index-key-too-long")

    def _maintain_indexes(self, key, old_doc, new_doc):
        """§14.3 step 3: bring every live index back in step, in slot order."""
        for slot in self.live_slots():
            s = self.pager.hdr.slots[slot]
            segs = self._segs(s.path)
            old_entry = None if old_doc is None else self._entry_key(segs, key, old_doc)
            new_entry = None if new_doc is None else self._entry_key(segs, key, new_doc)
            if old_entry is None and new_entry is None:
                continue
            tree = self._index_tree(slot)
            if old_entry is None:
                tree.insert((new_entry,))
                s.entries += 1
                self.pager.touch_header()
            elif new_entry is None:
                tree.delete(old_entry)
                s.entries -= 1
                self.pager.touch_header()
            elif old_entry != new_entry:
                tree.delete(old_entry)
                tree.insert((new_entry,))

    def _store_document(self, key, old_cell, old_doc, docbytes, new_doc):
        """§14.3 for put / update / unset: the primary tree, then the indexes."""
        if old_cell is not None:
            if old_cell[2]:
                free_overflow_chain(self.pager, old_cell[2])
            self.primary.insert(self._build_cell(key, docbytes))
        else:
            self.primary.insert(self._build_cell(key, docbytes))
            self.pager.hdr.primary_count += 1
            self.pager.touch_header()
        self._maintain_indexes(key, old_doc, new_doc)

    def put(self, key, value):
        docbytes = V.ser(value)
        if len(docbytes) > MAX_DOC:
            raise TessError("doc-too-large")
        self._check_index_keys(key, value)
        _p, old_cell = self.primary.find(key)
        old_doc = None if old_cell is None else self._read_doc(old_cell)

        def body():
            self._store_document(key, old_cell, old_doc, docbytes, value)
            return "replaced" if old_cell is not None else "created"

        return self._write(body)

    def delete(self, key):
        _p, cell = self.primary.find(key)
        if cell is None:
            raise TessError("not-found")
        old_doc = self._read_doc(cell)

        def body():
            if cell[2]:
                free_overflow_chain(self.pager, cell[2])
            self.primary.delete(key)
            self.pager.hdr.primary_count -= 1
            self.pager.touch_header()
            self._maintain_indexes(key, old_doc, None)

        return self._write(body)

    def update(self, key, segs, value):
        _p, old_cell = self.primary.find(key)
        if old_cell is None:
            raise TessError("not-found")
        old_doc = self._read_doc(old_cell)
        try:
            new_doc = V.path_set(old_doc, segs, value)
        except PathNotObject:
            raise TessError("not-object")
        if V.depth(new_doc) > V.MAX_DEPTH:
            raise TessError("depth")
        docbytes = V.ser(new_doc)
        if len(docbytes) > MAX_DOC:
            raise TessError("doc-too-large")
        self._check_index_keys(key, new_doc)

        def body():
            self._store_document(key, old_cell, old_doc, docbytes, new_doc)

        return self._write(body)

    def unset(self, key, segs):
        _p, old_cell = self.primary.find(key)
        if old_cell is None:
            raise TessError("not-found")
        old_doc = self._read_doc(old_cell)
        try:
            new_doc = V.path_unset(old_doc, segs)
        except PathNotObject:
            raise TessError("not-object")
        except PathNoField:
            raise TessError("no-field")
        docbytes = V.ser(new_doc)

        def body():
            self._store_document(key, old_cell, old_doc, docbytes, new_doc)

        return self._write(body)

    # ---- indexes (§14.4, §14.5) ------------------------------------------

    def _find_slot(self, path_text):
        for i, s in enumerate(self.pager.hdr.slots):
            if s.live and s.path == path_text:
                return i
        return -1

    def create_index(self, path_text):
        hdr = self.pager.hdr
        if self._find_slot(path_text) >= 0:
            raise TessError("index-exists")
        if hdr.index_count == MAX_INDEXES:
            raise TessError("index-limit")
        segs = self._segs(path_text)
        entries = []
        for cell in self.primary.iter_cells():
            doc = self._read_doc(cell)
            entry = self._entry_key(segs, cell[0], doc)
            if entry is None:
                continue
            if len(entry) > MAX_INDEX_KEY:
                raise TessError("index-key-too-long")
            entries.append(entry)
        slot = 0
        while hdr.slots[slot].live:
            slot += 1

        def body():
            s = self.pager.hdr.slots[slot]
            s.live = 1
            s.path = path_text
            s.root = 0
            s.entries = 0
            self.pager.hdr.index_count += 1
            self.pager.touch_header()
            tree = self._index_tree(slot)
            for entry in entries:
                tree.insert((entry,))
                self.pager.hdr.slots[slot].entries += 1
                self.pager.touch_header()
            return len(entries)

        return self._write(body)

    def drop_index(self, path_text):
        slot = self._find_slot(path_text)
        if slot < 0:
            raise TessError("index-missing")

        def body():
            tree = self._index_tree(slot)
            pages = list(tree.all_pages_postorder())
            for p in pages:
                self.pager.free_page(p)
            s = self.pager.hdr.slots[slot]
            s.live = 0
            s.path = b""
            s.root = 0
            s.entries = 0
            self.pager.hdr.index_count -= 1
            self.pager.touch_header()
            return len(pages)

        return self._write(body)

    def list_indexes(self):
        out = []
        for i in self.live_slots():
            s = self.pager.hdr.slots[i]
            out.append((i, s.path, s.root, s.entries))
        return out

    # ---- reads -----------------------------------------------------------

    def stat(self):
        hdr = self.pager.hdr
        return [("pages", hdr.page_count),
                ("free", hdr.freelist_count),
                ("freehead", hdr.freelist_head),
                ("docs", hdr.primary_count),
                ("root", hdr.primary_root),
                ("height", self.primary.height()),
                ("commits", hdr.commit_counter),
                ("indexes", hdr.index_count),
                ("wal", self.pager.wal_size())]

    def scan(self, frm, to, limit, reverse, keys_only):
        # An ascending scan with a limit can stop as soon as it has enough
        # rows; a reverse scan has to see the whole range before it can order
        # it. Either way the rows are the same (SPEC 6.5).
        stop_at = None if reverse else limit
        cells = []
        for cell in self.primary.iter_cells(frm):
            if to is not None and cell[0] >= to:
                break
            cells.append(cell)
            if stop_at is not None and len(cells) >= stop_at:
                break
        if reverse:
            cells.reverse()
        if limit is not None and len(cells) > limit:
            cells = cells[:limit]
        if keys_only:
            return [(c[0], None) for c in cells]
        return [(c[0], self._read_doc(c)) for c in cells]

    # ---- queries (§17) ---------------------------------------------------

    def _eval(self, node, doc):
        kind = node[0]
        if kind == "or":
            return self._eval(node[1], doc) or self._eval(node[2], doc)
        if kind == "and":
            return self._eval(node[1], doc) and self._eval(node[2], doc)
        if kind == "not":
            return not self._eval(node[1], doc)
        if kind == "exists":
            return V.path_resolve(doc, node[1]) is not None
        if kind == "missing":
            return V.path_resolve(doc, node[1]) is None
        segs, op, value = node[1], node[2], node[3]
        x = V.path_resolve(doc, segs)
        if x is None:
            return False
        if op == "==":
            return V.veq(x, value)
        if op == "!=":
            return not V.veq(x, value)
        c = V.vorder(x, value)
        if c is None:
            return False
        if op == "<":
            return c < 0
        if op == "<=":
            return c <= 0
        if op == ">":
            return c > 0
        return c >= 0

    @staticmethod
    def _flatten_and(node, out):
        if node[0] == "and":
            Store._flatten_and(node[1], out)
            Store._flatten_and(node[2], out)
        else:
            out.append(node)

    def choose_plan(self, pred):
        """§17.3: the single best usable leaf, or None for a scan plan."""
        leaves = []
        self._flatten_and(pred, leaves)
        best = None
        for leaf in leaves:
            if leaf[0] != "cmp":
                continue
            segs, op, value, order = leaf[1], leaf[2], leaf[3], leaf[4]
            if op == "!=":
                continue
            if value[0] == LIST or value[0] == OBJ:
                continue
            path_text = b".".join(segs)
            slot = self._find_slot(path_text)
            if slot < 0:
                continue
            rank = (0 if op == "==" else 1, path_text, order)
            if best is None or rank < best[0]:
                best = (rank, slot, op, value)
        return best

    def _candidates(self, slot, op, value):
        """Index keys in the candidate range of §17.3, in index-key order."""
        tree = self._index_tree(slot)
        vk = V.vkey(value)
        if op == "<" or op == "<=":
            for cell in tree.iter_cells():
                ikey = cell[0]
                if ikey < vk:
                    yield ikey
                elif op == "<=" and ikey.startswith(vk):
                    yield ikey
                else:
                    break
        elif op == "==":
            for cell in tree.iter_cells(vk):
                if cell[0].startswith(vk):
                    yield cell[0]
                else:
                    break
        elif op == ">":
            for cell in tree.iter_cells(vk):
                if cell[0] > vk and not cell[0].startswith(vk):
                    yield cell[0]
        else:
            for cell in tree.iter_cells(vk):
                if cell[0] >= vk:
                    yield cell[0]

    def find(self, pred, limit):
        best = self.choose_plan(pred)
        rows = []
        if best is None:
            plan = None
            for cell in self.primary.iter_cells():
                doc = self._read_doc(cell)
                if self._eval(pred, doc):
                    rows.append((cell[0], doc))
        else:
            _rank, slot, op, value = best
            plan = self.pager.hdr.slots[slot].path
            for ikey in self._candidates(slot, op, value):
                key = ikey[V.vkey_len(ikey):]
                _p, cell = self.primary.find(key)
                if cell is None:
                    continue
                doc = self._read_doc(cell)
                if self._eval(pred, doc):
                    rows.append((key, doc))
            rows.sort(key=lambda r: r[0])
        if limit is not None and len(rows) > limit:
            rows = rows[:limit]
        return plan, rows

    # ---- output ----------------------------------------------------------

    def main_bytes(self):
        return bytes(self.pager.main)

    def wal_bytes(self):
        return bytes(self.pager.wal)
