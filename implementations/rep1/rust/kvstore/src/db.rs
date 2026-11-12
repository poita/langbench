//! The database engine: opening and recovery, transactions, document
//! operations, secondary indexes and queries.

use std::collections::BTreeMap;

use crate::btree::{self, Cell, Cursor, RevCursor};
use crate::command::ScanOptions;
use crate::error::{Error, Result};
use crate::header::{Header, IndexSlot, Page};
use crate::index::{entry_key, vkey_len};
use crate::overflow;
use crate::pager::{CommitInfo, Pager, TreeId};
use crate::path::Path;
use crate::predicate::{choose_plan, CmpOp, Plan, Pred};
use crate::value::Value;
use crate::wal;
use crate::{MAX_DEPTH, MAX_DOC, MAX_INDEXES, MAX_INDEX_KEY, MAX_KEY, PAGE_SIZE};

/// Whether `put` created a new document or replaced an existing one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PutOutcome {
    /// The key was new.
    Created,
    /// The key existed and its document was replaced.
    Replaced,
}

/// The nine counters printed by `stat`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stat {
    /// Pages in the database (`page_count`).
    pub pages: u32,
    /// Pages on the free list.
    pub free: u32,
    /// Head of the free list.
    pub freehead: u32,
    /// Number of documents.
    pub docs: u32,
    /// Root page of the primary tree.
    pub root: u32,
    /// Height of the primary tree.
    pub height: u32,
    /// Committed transactions over the database's lifetime.
    pub commits: u64,
    /// Live secondary indexes.
    pub indexes: u32,
    /// Size of the log in bytes.
    pub wal: u32,
}

/// One live secondary index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexInfo {
    /// Directory slot (0-based).
    pub slot: usize,
    /// Path text.
    pub path: String,
    /// Root page of the index tree.
    pub root: u32,
    /// Number of entries.
    pub entries: u32,
}

/// The result of a `find`.
#[derive(Clone, Debug, PartialEq)]
pub struct FindResult {
    /// The plan that was used.
    pub plan: Plan,
    /// Matching documents in ascending key order.
    pub rows: Vec<(Vec<u8>, Value)>,
}

/// A row of a `scan`: the key and, unless only keys were requested, the document.
pub type ScanRow = (Vec<u8>, Option<Value>);

/// An open Tessera database held in memory.
///
/// The database consists of the two files `main.tdb` and `main.twal`; this
/// type works on their byte images ([`Database::open`],
/// [`Database::main_bytes`], [`Database::wal_bytes`]) and leaves file I/O to
/// the caller.
pub struct Database {
    pager: Pager,
    txn_open: bool,
}

impl Default for Database {
    fn default() -> Self {
        Database::new()
    }
}

fn check_key(key: &[u8]) -> Result<()> {
    if key.is_empty() || key.len() > MAX_KEY {
        Err(Error::BadKey)
    } else {
        Ok(())
    }
}

impl Database {
    /// A fresh, empty database.
    pub fn new() -> Database {
        Database::open(None, None).expect("a fresh database is valid")
    }

    /// Opens a database from the contents of its files, recovering from the
    /// log (spec §16): committed transactions are replayed into an overlay
    /// and everything after the last commit record is dropped. The main file
    /// is not modified.
    ///
    /// A missing or empty `main` is a fresh database; a missing or
    /// header-damaged `wal` is an empty log. Returns [`Error::Corrupt`] if
    /// `main` is not a database file.
    pub fn open(main: Option<&[u8]>, wal_bytes: Option<&[u8]>) -> Result<Database> {
        let main = match main {
            Some(m) if !m.is_empty() => {
                if m.len() % PAGE_SIZE != 0 {
                    return Err(Error::Corrupt);
                }
                m.to_vec()
            }
            _ => Header::fresh().encode().to_vec(),
        };
        let (overlay, log): (BTreeMap<u32, Page>, Vec<u8>) = match wal_bytes {
            Some(w) if wal::header_valid(w) => {
                let r = wal::scan(w);
                (r.overlay, w[..r.valid_end].to_vec())
            }
            _ => (BTreeMap::new(), wal::header_bytes().to_vec()),
        };
        Ok(Database { pager: Pager::new(main, overlay, log)?, txn_open: false })
    }

    /// The bytes of `main.tdb` as they would be written now.
    pub fn main_bytes(&self) -> &[u8] {
        self.pager.main_bytes()
    }

    /// The bytes of `main.twal` as they would be written now.
    pub fn wal_bytes(&self) -> &[u8] {
        self.pager.wal_bytes()
    }

    /// Whether an explicit transaction is open.
    pub fn in_transaction(&self) -> bool {
        self.txn_open
    }

    // ----- transactions -------------------------------------------------

    /// Opens an explicit transaction.
    pub fn begin(&mut self) -> Result<()> {
        if self.txn_open {
            return Err(Error::TxnActive);
        }
        self.txn_open = true;
        Ok(())
    }

    /// Commits the explicit transaction.
    pub fn commit(&mut self) -> Result<CommitInfo> {
        if !self.txn_open {
            return Err(Error::NoTxn);
        }
        self.txn_open = false;
        Ok(self.pager.commit())
    }

    /// Discards the explicit transaction.
    pub fn rollback(&mut self) -> Result<()> {
        if !self.txn_open {
            return Err(Error::NoTxn);
        }
        self.txn_open = false;
        self.pager.rollback();
        Ok(())
    }

    /// Copies the log into the main file and empties the log. Returns the
    /// number of pages copied.
    pub fn checkpoint(&mut self) -> Result<usize> {
        if self.txn_open {
            return Err(Error::TxnActive);
        }
        Ok(self.pager.checkpoint())
    }

    /// Runs a write inside the open transaction, or inside an implicit one
    /// that is committed on success.
    fn with_txn<T>(&mut self, f: impl FnOnce(&mut Database) -> Result<T>) -> Result<T> {
        if self.txn_open {
            return f(self);
        }
        match f(self) {
            Ok(v) => {
                self.pager.commit();
                Ok(v)
            }
            Err(e) => {
                self.pager.rollback();
                Err(e)
            }
        }
    }

    // ----- helpers ------------------------------------------------------

    fn live_slots(&self) -> Vec<(usize, Vec<String>)> {
        self.pager
            .header
            .slots
            .iter()
            .enumerate()
            .filter(|(_, s)| s.live)
            .map(|(i, s)| (i, s.path.split('.').map(str::to_string).collect()))
            .collect()
    }

    /// The index key of `doc` for every live slot (`None` where the document
    /// is not indexable or the slot is unused).
    fn entry_keys(&self, doc: &Value, key: &[u8]) -> Vec<Option<Vec<u8>>> {
        let mut keys = vec![None; MAX_INDEXES];
        for (slot, segs) in self.live_slots() {
            keys[slot] = entry_key(&segs, doc, key);
        }
        keys
    }

    fn load_value(&self, cell: &Cell) -> Result<Value> {
        Value::deserialize(&overflow::read_document(&self.pager, cell)?)
    }

    fn has_indexes(&self) -> bool {
        self.pager.header.slots.iter().any(|s| s.live)
    }

    // ----- documents ----------------------------------------------------

    /// Stores `doc` under `key`, replacing any existing document.
    ///
    /// Errors: [`Error::BadKey`], [`Error::Depth`], [`Error::DocTooLarge`],
    /// [`Error::IndexKeyTooLong`]. A failed put changes nothing.
    pub fn put(&mut self, key: &[u8], doc: &Value) -> Result<PutOutcome> {
        check_key(key)?;
        if doc.depth() > MAX_DEPTH {
            return Err(Error::Depth);
        }
        let ser = doc.serialize();
        if ser.len() > MAX_DOC {
            return Err(Error::DocTooLarge);
        }
        let new_keys = self.entry_keys(doc, key);
        if new_keys.iter().flatten().any(|k| k.len() > MAX_INDEX_KEY) {
            return Err(Error::IndexKeyTooLong);
        }
        self.with_txn(|db| db.write_document(key, &ser, new_keys))
    }

    /// Writes the serialised document and brings the indexes up to date
    /// (spec §14.3). All validation has been done by the caller.
    fn write_document(&mut self, key: &[u8], ser: &[u8], new_keys: Vec<Option<Vec<u8>>>) -> Result<PutOutcome> {
        let old = btree::get(&self.pager, TreeId::Primary, key)?;
        let mut old_keys = vec![None; MAX_INDEXES];
        if let Some(cell) = &old {
            if self.has_indexes() {
                let old_doc = self.load_value(cell)?;
                old_keys = self.entry_keys(&old_doc, key);
            }
            overflow::free_chain(&mut self.pager, cell.overflow);
        }
        let cell = overflow::build_cell(&mut self.pager, key, ser);
        let replaced = btree::insert(&mut self.pager, TreeId::Primary, cell)?;
        if !replaced {
            self.pager.header.primary_count += 1;
        }
        for (slot, _) in self.live_slots() {
            self.update_index(slot, old_keys[slot].as_deref(), new_keys[slot].as_deref())?;
        }
        Ok(if replaced { PutOutcome::Replaced } else { PutOutcome::Created })
    }

    fn update_index(&mut self, slot: usize, old: Option<&[u8]>, new: Option<&[u8]>) -> Result<()> {
        let tree = TreeId::Index(slot);
        match (old, new) {
            (None, None) => {}
            (None, Some(n)) => {
                btree::insert(&mut self.pager, tree, Cell::index(n.to_vec()))?;
                self.pager.header.slots[slot].entries += 1;
            }
            (Some(o), None) => {
                btree::delete(&mut self.pager, tree, o)?;
                self.pager.header.slots[slot].entries -= 1;
            }
            (Some(o), Some(n)) => {
                if o != n {
                    btree::delete(&mut self.pager, tree, o)?;
                    btree::insert(&mut self.pager, tree, Cell::index(n.to_vec()))?;
                }
            }
        }
        Ok(())
    }

    /// Returns the document stored under `key`.
    pub fn get(&self, key: &[u8]) -> Result<Value> {
        check_key(key)?;
        let cell = btree::get(&self.pager, TreeId::Primary, key)?.ok_or(Error::NotFound)?;
        self.load_value(&cell)
    }

    /// Deletes the document under `key`.
    pub fn delete(&mut self, key: &[u8]) -> Result<()> {
        check_key(key)?;
        let cell = btree::get(&self.pager, TreeId::Primary, key)?.ok_or(Error::NotFound)?;
        self.with_txn(|db| {
            let old_keys = if db.has_indexes() {
                let old = db.load_value(&cell)?;
                db.entry_keys(&old, key)
            } else {
                vec![None; MAX_INDEXES]
            };
            overflow::free_chain(&mut db.pager, cell.overflow);
            btree::delete(&mut db.pager, TreeId::Primary, key)?;
            db.pager.header.primary_count -= 1;
            for (slot, _) in db.live_slots() {
                db.update_index(slot, old_keys[slot].as_deref(), None)?;
            }
            Ok(())
        })
    }

    /// Sets the field at `path` of the document under `key`, creating empty
    /// objects for missing intermediate segments.
    pub fn update(&mut self, key: &[u8], path: &Path, value: Value) -> Result<()> {
        check_key(key)?;
        let cell = btree::get(&self.pager, TreeId::Primary, key)?.ok_or(Error::NotFound)?;
        let mut doc = self.load_value(&cell)?;
        doc.set_path(path.segments(), value)?;
        self.store_modified(key, &doc)
    }

    /// Removes the field at `path` of the document under `key`.
    pub fn unset(&mut self, key: &[u8], path: &Path) -> Result<()> {
        check_key(key)?;
        let cell = btree::get(&self.pager, TreeId::Primary, key)?.ok_or(Error::NotFound)?;
        let mut doc = self.load_value(&cell)?;
        doc.unset_path(path.segments())?;
        self.store_modified(key, &doc)
    }

    fn store_modified(&mut self, key: &[u8], doc: &Value) -> Result<()> {
        if doc.depth() > MAX_DEPTH {
            return Err(Error::Depth);
        }
        let ser = doc.serialize();
        if ser.len() > MAX_DOC {
            return Err(Error::DocTooLarge);
        }
        let new_keys = self.entry_keys(doc, key);
        if new_keys.iter().flatten().any(|k| k.len() > MAX_INDEX_KEY) {
            return Err(Error::IndexKeyTooLong);
        }
        self.with_txn(|db| db.write_document(key, &ser, new_keys)).map(|_| ())
    }

    // ----- scans and queries --------------------------------------------

    fn scan_row(&self, cell: Cell, keys_only: bool) -> Result<ScanRow> {
        let doc = if keys_only { None } else { Some(self.load_value(&cell)?) };
        Ok((cell.key, doc))
    }

    /// Scans the primary tree in key order (or reverse), honouring the
    /// bounds and limit of `opts`. Reads only the documents it emits, and
    /// none when only keys are requested.
    pub fn scan(&self, opts: &ScanOptions) -> Result<Vec<ScanRow>> {
        let limit = opts.limit.map_or(usize::MAX, |l| l as usize);
        let mut rows = Vec::new();
        if limit == 0 {
            return Ok(rows);
        }
        if opts.reverse {
            let mut cur = RevCursor::seek(&self.pager, TreeId::Primary, opts.to.as_deref())?;
            while let Some(cell) = cur.next(&self.pager)? {
                if opts.from.as_deref().is_some_and(|f| cell.key.as_slice() < f) {
                    break;
                }
                rows.push(self.scan_row(cell, opts.keys_only)?);
                if rows.len() >= limit {
                    break;
                }
            }
        } else {
            let mut cur = Cursor::seek(&self.pager, TreeId::Primary, opts.from.as_deref())?;
            while let Some(cell) = cur.next(&self.pager)? {
                if opts.to.as_deref().is_some_and(|t| cell.key.as_slice() >= t) {
                    break;
                }
                rows.push(self.scan_row(cell, opts.keys_only)?);
                if rows.len() >= limit {
                    break;
                }
            }
        }
        Ok(rows)
    }

    /// Evaluates `pred` against the store, returning the matches in
    /// ascending key order, at most `limit` of them, together with the plan
    /// that was used (spec §17).
    pub fn find(&self, pred: &Pred, limit: Option<u32>) -> Result<FindResult> {
        let limit = limit.map_or(usize::MAX, |l| l as usize);
        let paths: Vec<&str> = self.pager.header.slots.iter().filter(|s| s.live).map(|s| s.path.as_str()).collect();
        let plan = choose_plan(pred, &paths);
        let mut rows = Vec::new();
        if limit == 0 {
            return Ok(FindResult { plan, rows });
        }
        match &plan {
            Plan::Scan => {
                let mut cur = Cursor::seek(&self.pager, TreeId::Primary, None)?;
                while let Some(cell) = cur.next(&self.pager)? {
                    let doc = self.load_value(&cell)?;
                    if pred.eval(&doc) {
                        rows.push((cell.key, doc));
                        if rows.len() >= limit {
                            break;
                        }
                    }
                }
            }
            Plan::Index { path, op, vkey } => {
                let slot = self
                    .pager
                    .header
                    .slots
                    .iter()
                    .position(|s| s.live && &s.path == path)
                    .ok_or(Error::Corrupt)?;
                let mut keys = self.candidate_keys(slot, *op, vkey)?;
                keys.sort();
                for key in keys {
                    let cell = btree::get(&self.pager, TreeId::Primary, &key)?.ok_or(Error::Corrupt)?;
                    let doc = self.load_value(&cell)?;
                    if pred.eval(&doc) {
                        rows.push((key, doc));
                        if rows.len() >= limit {
                            break;
                        }
                    }
                }
            }
        }
        Ok(FindResult { plan, rows })
    }

    /// Document keys of the index entries in the candidate range of
    /// `op vkey` (spec §17.3), in index-key order.
    fn candidate_keys(&self, slot: usize, op: CmpOp, v: &[u8]) -> Result<Vec<Vec<u8>>> {
        let tree = TreeId::Index(slot);
        let start = match op {
            CmpOp::Eq | CmpOp::Gt | CmpOp::Ge => Some(v),
            _ => None,
        };
        let mut cur = Cursor::seek(&self.pager, tree, start)?;
        let mut keys = Vec::new();
        while let Some(cell) = cur.next(&self.pager)? {
            let k = cell.key.as_slice();
            let prefixed = k.starts_with(v);
            match op {
                CmpOp::Eq if !prefixed => break,
                CmpOp::Lt if k >= v => break,
                CmpOp::Le if k >= v && !prefixed => break,
                CmpOp::Gt if prefixed => continue,
                _ => {}
            }
            keys.push(k[vkey_len(k)..].to_vec());
        }
        Ok(keys)
    }

    // ----- indexes ------------------------------------------------------

    /// Builds a secondary index on `path`; returns its entry count.
    pub fn create_index(&mut self, path: &Path) -> Result<u32> {
        let header = &self.pager.header;
        if header.slots.iter().any(|s| s.live && s.path == path.text()) {
            return Err(Error::IndexExists);
        }
        if header.index_count() as usize == MAX_INDEXES {
            return Err(Error::IndexLimit);
        }
        // One pass over the primary tree, in key order.
        let mut entries = Vec::new();
        let mut cur = Cursor::seek(&self.pager, TreeId::Primary, None)?;
        while let Some(cell) = cur.next(&self.pager)? {
            let doc = self.load_value(&cell)?;
            if let Some(k) = entry_key(path.segments(), &doc, &cell.key) {
                if k.len() > MAX_INDEX_KEY {
                    return Err(Error::IndexKeyTooLong);
                }
                entries.push(k);
            }
        }
        let path = path.text().to_string();
        self.with_txn(|db| {
            let slot = db.pager.header.slots.iter().position(|s| !s.live).ok_or(Error::IndexLimit)?;
            db.pager.header.slots[slot] = IndexSlot { live: true, path, root: 0, entries: 0 };
            let n = entries.len() as u32;
            for k in entries {
                btree::insert(&mut db.pager, TreeId::Index(slot), Cell::index(k))?;
            }
            db.pager.header.slots[slot].entries = n;
            Ok(n)
        })
    }

    /// Drops the index on `path`; returns the number of pages freed.
    pub fn drop_index(&mut self, path: &Path) -> Result<usize> {
        let slot = self
            .pager
            .header
            .slots
            .iter()
            .position(|s| s.live && s.path == path.text())
            .ok_or(Error::IndexMissing)?;
        self.with_txn(|db| {
            let root = db.pager.header.slots[slot].root;
            let freed = btree::free_tree(&mut db.pager, root)?;
            db.pager.header.slots[slot] = IndexSlot::default();
            Ok(freed)
        })
    }

    /// The live indexes in slot order.
    pub fn indexes(&self) -> Vec<IndexInfo> {
        self.pager
            .header
            .slots
            .iter()
            .enumerate()
            .filter(|(_, s)| s.live)
            .map(|(slot, s)| IndexInfo { slot, path: s.path.clone(), root: s.root, entries: s.entries })
            .collect()
    }

    /// The counters printed by `stat`.
    pub fn stat(&self) -> Result<Stat> {
        let h = &self.pager.header;
        Ok(Stat {
            pages: h.page_count,
            free: h.freelist_count,
            freehead: h.freelist_head,
            docs: h.primary_count,
            root: h.primary_root,
            height: btree::height(&self.pager, TreeId::Primary)? as u32,
            commits: h.commit_counter,
            indexes: h.index_count(),
            wal: self.pager.wal_len() as u32,
        })
    }
}
