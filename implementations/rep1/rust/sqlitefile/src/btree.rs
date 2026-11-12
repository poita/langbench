//! B-tree traversal: table scans, counting, rowid seeks and index lookups
//! (SPEC §§1.2–1.7).
//!
//! All functions take the root page number of a B-tree and walk it from
//! there; nothing is cached between calls.

use crate::error::{Error, Result};
use crate::pager::Database;
use crate::record::Record;
use crate::value::Value;
use crate::varint;
use std::borrow::Cow;
use std::cmp::Ordering;

/// Deeper than any real tree; protects against cyclic corrupt files.
const MAX_DEPTH: usize = 64;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    InteriorIndex,
    InteriorTable,
    LeafIndex,
    LeafTable,
}

fn be16(page: &[u8], off: usize) -> Result<usize> {
    match page.get(off..off + 2) {
        Some(b) => Ok(usize::from(u16::from_be_bytes([b[0], b[1]]))),
        None => Err(Error::corrupt("read past end of page")),
    }
}

fn be32(page: &[u8], off: usize) -> Result<u32> {
    match page.get(off..off + 4) {
        Some(b) => Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]])),
        None => Err(Error::corrupt("read past end of page")),
    }
}

fn varint_at(page: &[u8], off: usize) -> Result<(i64, usize)> {
    varint::read(page, off).ok_or_else(|| Error::corrupt("varint past end of page"))
}

/// A decoded B-tree page header plus access to its cells.
struct Node<'a> {
    db: &'a Database,
    kind: Kind,
    page: &'a [u8],
    ncells: usize,
    ptr_start: usize,
    right: u32,
}

impl<'a> Node<'a> {
    fn load(db: &'a Database, pageno: u32) -> Result<Node<'a>> {
        let page = db.page(pageno)?;
        let base = if pageno == 1 { 100 } else { 0 };
        let kind = match page.get(base) {
            Some(0x02) => Kind::InteriorIndex,
            Some(0x05) => Kind::InteriorTable,
            Some(0x0a) => Kind::LeafIndex,
            Some(0x0d) => Kind::LeafTable,
            _ => return Err(Error::corrupt(format!("page {pageno} is not a b-tree page"))),
        };
        let interior = matches!(kind, Kind::InteriorIndex | Kind::InteriorTable);
        let ncells = be16(page, base + 3)?;
        let (ptr_start, right) = if interior {
            (base + 12, be32(page, base + 8)?)
        } else {
            (base + 8, 0)
        };
        if ptr_start + 2 * ncells > page.len() {
            return Err(Error::corrupt("cell pointer array overflows page"));
        }
        Ok(Node { db, kind, page, ncells, ptr_start, right })
    }

    /// Offset of cell `i` within the page.
    fn cell(&self, i: usize) -> Result<usize> {
        let off = be16(self.page, self.ptr_start + 2 * i)?;
        if off >= self.page.len() {
            return Err(Error::corrupt("cell offset out of range"));
        }
        Ok(off)
    }

    /// Left child page of interior cell `i`.
    fn left_child(&self, i: usize) -> Result<u32> {
        be32(self.page, self.cell(i)?)
    }

    /// Rowid of table leaf cell `i`, without touching its payload.
    fn leaf_rowid(&self, i: usize) -> Result<i64> {
        let off = self.cell(i)?;
        let (_, n) = varint_at(self.page, off)?;
        Ok(varint_at(self.page, off + n)?.0)
    }

    /// Key of table interior cell `i`.
    fn interior_rowid(&self, i: usize) -> Result<i64> {
        Ok(varint_at(self.page, self.cell(i)? + 4)?.0)
    }

    /// Rowid and full payload of table leaf cell `i`.
    fn table_leaf_cell(&self, i: usize) -> Result<(i64, Cow<'a, [u8]>)> {
        let off = self.cell(i)?;
        let (p, n1) = varint_at(self.page, off)?;
        let (rowid, n2) = varint_at(self.page, off + n1)?;
        let payload = payload(self.db, self.page, off + n1 + n2, p, true)?;
        Ok((rowid, payload))
    }

    /// Full payload of index cell `i` (leaf or interior).
    fn index_cell(&self, i: usize) -> Result<Cow<'a, [u8]>> {
        let mut off = self.cell(i)?;
        if self.kind == Kind::InteriorIndex {
            off += 4;
        }
        let (p, n) = varint_at(self.page, off)?;
        payload(self.db, self.page, off + n, p, false)
    }
}

/// Gather the payload of a cell, following the overflow chain if needed
/// (SPEC §1.5). `start` is the offset of the first local payload byte.
fn payload<'a>(
    db: &'a Database,
    page: &'a [u8],
    start: usize,
    total: i64,
    table_leaf: bool,
) -> Result<Cow<'a, [u8]>> {
    let total = usize::try_from(total).map_err(|_| Error::corrupt("negative payload size"))?;
    if total > db.len() {
        return Err(Error::corrupt("payload larger than file"));
    }
    let u = db.usable_size();
    let m = (u - 12) * 32 / 255 - 23;
    let x = if table_leaf { u - 35 } else { (u - 12) * 64 / 255 - 23 };
    let local = if total <= x {
        total
    } else {
        let k = m + (total - m) % (u - 4);
        if k <= x {
            k
        } else {
            m
        }
    };
    let end = start + local;
    let local_bytes = page
        .get(start..end)
        .ok_or_else(|| Error::corrupt("cell payload past end of page"))?;
    if local == total {
        return Ok(Cow::Borrowed(local_bytes));
    }
    let mut next = be32(page, end)?;
    let mut buf = Vec::with_capacity(total);
    buf.extend_from_slice(local_bytes);
    while buf.len() < total {
        if next == 0 {
            return Err(Error::corrupt("overflow chain ends early"));
        }
        let p = db.page(next)?;
        let take = (u - 4).min(total - buf.len());
        let chunk = p
            .get(4..4 + take)
            .ok_or_else(|| Error::corrupt("overflow page too short"))?;
        buf.extend_from_slice(chunk);
        next = be32(p, 0)?;
    }
    Ok(Cow::Owned(buf))
}

fn check_depth(depth: usize) -> Result<()> {
    if depth > MAX_DEPTH {
        Err(Error::corrupt("b-tree too deep (cycle?)"))
    } else {
        Ok(())
    }
}

fn not_table() -> Error {
    Error::corrupt("expected a table b-tree page")
}

/// Visit every row of the table B-tree rooted at `root` in ascending rowid
/// order, calling `f(rowid, payload)`. The callback returns `Ok(true)` to
/// continue or `Ok(false)` to stop early.
pub fn table_scan<F>(db: &Database, root: u32, mut f: F) -> Result<()>
where
    F: FnMut(i64, &[u8]) -> Result<bool>,
{
    scan_rec(db, root, 0, &mut f).map(|_| ())
}

fn scan_rec<F>(db: &Database, pageno: u32, depth: usize, f: &mut F) -> Result<bool>
where
    F: FnMut(i64, &[u8]) -> Result<bool>,
{
    check_depth(depth)?;
    let node = Node::load(db, pageno)?;
    match node.kind {
        Kind::LeafTable => {
            for i in 0..node.ncells {
                let (rowid, data) = node.table_leaf_cell(i)?;
                if !f(rowid, &data)? {
                    return Ok(false);
                }
            }
            Ok(true)
        }
        Kind::InteriorTable => {
            for i in 0..node.ncells {
                if !scan_rec(db, node.left_child(i)?, depth + 1, f)? {
                    return Ok(false);
                }
            }
            scan_rec(db, node.right, depth + 1, f)
        }
        _ => Err(not_table()),
    }
}

/// Count the rows of a table B-tree by summing the cell counts of its leaves.
/// No record is decoded.
pub fn table_count(db: &Database, root: u32) -> Result<u64> {
    fn rec(db: &Database, pageno: u32, depth: usize) -> Result<u64> {
        check_depth(depth)?;
        let node = Node::load(db, pageno)?;
        match node.kind {
            Kind::LeafTable => Ok(node.ncells as u64),
            Kind::InteriorTable => {
                let mut n = 0;
                for i in 0..node.ncells {
                    n += rec(db, node.left_child(i)?, depth + 1)?;
                }
                Ok(n + rec(db, node.right, depth + 1)?)
            }
            _ => Err(not_table()),
        }
    }
    rec(db, root, 0)
}

/// Find the row with the given rowid in a table B-tree, returning its payload.
pub fn table_find(db: &Database, root: u32, rowid: i64) -> Result<Option<Vec<u8>>> {
    let mut pageno = root;
    for _ in 0..=MAX_DEPTH {
        let node = Node::load(db, pageno)?;
        match node.kind {
            Kind::InteriorTable => {
                // First cell whose key is >= rowid.
                let (mut lo, mut hi) = (0, node.ncells);
                while lo < hi {
                    let mid = (lo + hi) / 2;
                    if node.interior_rowid(mid)? < rowid {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                pageno = if lo < node.ncells { node.left_child(lo)? } else { node.right };
            }
            Kind::LeafTable => {
                let (mut lo, mut hi) = (0, node.ncells);
                while lo < hi {
                    let mid = (lo + hi) / 2;
                    if node.leaf_rowid(mid)? < rowid {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                if lo < node.ncells && node.leaf_rowid(lo)? == rowid {
                    let (_, data) = node.table_leaf_cell(lo)?;
                    return Ok(Some(data.into_owned()));
                }
                return Ok(None);
            }
            _ => return Err(not_table()),
        }
    }
    Err(Error::corrupt("b-tree too deep (cycle?)"))
}

/// Comparison of an index entry's leading column with `key`, and its rowid.
fn entry_key(node: &Node<'_>, i: usize) -> Result<(Value, i64)> {
    let data = node.index_cell(i)?;
    let rec = Record::parse(&data)?;
    if rec.len() < 2 {
        return Err(Error::corrupt("index entry too short"));
    }
    let rowid = match rec.get(rec.len() - 1)? {
        Value::Integer(r) => r,
        _ => return Err(Error::corrupt("index entry rowid is not an integer")),
    };
    Ok((rec.get(0)?, rowid))
}

/// Collect the rowids of every entry of the index B-tree at `root` whose
/// first column equals `key` (SPEC Part 3 comparison). Entries are found by a
/// binary search at each level, then walked in key order, including the
/// entries stored in interior pages. Rowids come out in index order.
pub fn index_lookup(db: &Database, root: u32, key: &Value) -> Result<Vec<i64>> {
    let mut out = Vec::new();
    index_rec(db, root, 0, key, &mut out)?;
    Ok(out)
}

/// Returns `Ok(false)` once an entry greater than `key` has been seen.
fn index_rec(
    db: &Database,
    pageno: u32,
    depth: usize,
    key: &Value,
    out: &mut Vec<i64>,
) -> Result<bool> {
    check_depth(depth)?;
    let node = Node::load(db, pageno)?;
    let interior = match node.kind {
        Kind::LeafIndex => false,
        Kind::InteriorIndex => true,
        _ => return Err(Error::corrupt("expected an index b-tree page")),
    };
    // First cell whose key is >= `key`.
    let (mut lo, mut hi) = (0, node.ncells);
    while lo < hi {
        let mid = (lo + hi) / 2;
        if entry_key(&node, mid)?.0.compare(key) == Ordering::Less {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    for i in lo..node.ncells {
        if interior && !index_rec(db, node.left_child(i)?, depth + 1, key, out)? {
            return Ok(false);
        }
        let (k, rowid) = entry_key(&node, i)?;
        match k.compare(key) {
            Ordering::Equal => out.push(rowid),
            Ordering::Greater => return Ok(false),
            Ordering::Less => {}
        }
    }
    if interior {
        return index_rec(db, node.right, depth + 1, key, out);
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a 512-byte-page database whose page 2 is a table leaf with the
    /// given (rowid, payload) cells.
    fn leaf_db(cells: &[(i64, Vec<u8>)]) -> Database {
        let mut data = vec![0u8; 1024];
        data[..16].copy_from_slice(b"SQLite format 3\0");
        data[16..18].copy_from_slice(&512u16.to_be_bytes());
        let page = &mut data[512..];
        page[0] = 0x0d;
        page[3..5].copy_from_slice(&(cells.len() as u16).to_be_bytes());
        let mut end = 512;
        for (i, (rowid, p)) in cells.iter().enumerate() {
            let mut cell = vec![p.len() as u8, *rowid as u8];
            cell.extend(p);
            end -= cell.len();
            page[end..end + cell.len()].copy_from_slice(&cell);
            page[8 + 2 * i..10 + 2 * i].copy_from_slice(&(end as u16).to_be_bytes());
        }
        Database::from_bytes(data).unwrap()
    }

    #[test]
    fn scans_leaf_in_order_and_stops_early() {
        let db = leaf_db(&[(1, vec![1, 2]), (2, vec![3]), (5, vec![])]);
        let mut seen = vec![];
        table_scan(&db, 2, |r, p| {
            seen.push((r, p.to_vec()));
            Ok(r < 2)
        })
        .unwrap();
        assert_eq!(seen, vec![(1, vec![1, 2]), (2, vec![3])]);
        assert_eq!(table_count(&db, 2).unwrap(), 3);
    }

    #[test]
    fn finds_by_rowid() {
        let db = leaf_db(&[(1, vec![1]), (3, vec![3]), (9, vec![9])]);
        assert_eq!(table_find(&db, 2, 3).unwrap(), Some(vec![3]));
        assert_eq!(table_find(&db, 2, 9).unwrap(), Some(vec![9]));
        assert_eq!(table_find(&db, 2, 4).unwrap(), None);
        assert_eq!(table_find(&db, 2, 0).unwrap(), None);
    }

    #[test]
    fn non_btree_page_is_an_error() {
        let db = leaf_db(&[]);
        assert!(table_count(&db, 1).is_err()); // page 1 byte 100 is 0
        assert!(table_count(&db, 7).is_err());
    }
}
