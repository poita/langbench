//! A tiny SQLite file *writer* used to build fixtures for the tests.
//!
//! It supports just enough of the format to exercise the reader: table and
//! index B-trees with one interior level, payload overflow, and a schema page.

#![allow(dead_code)]

use sqlitefile::Value;

pub fn varint(v: i64) -> Vec<u8> {
    let u = v as u64;
    if u >> 56 != 0 {
        let mut out = vec![0u8; 9];
        out[8] = (u & 0xff) as u8;
        let mut r = u >> 8;
        for i in (0..8).rev() {
            out[i] = ((r & 0x7f) as u8) | 0x80;
            r >>= 7;
        }
        out
    } else {
        let mut bytes = Vec::new();
        let mut r = u;
        loop {
            bytes.push((r & 0x7f) as u8);
            r >>= 7;
            if r == 0 {
                break;
            }
        }
        bytes.reverse();
        let n = bytes.len();
        for b in &mut bytes[..n - 1] {
            *b |= 0x80;
        }
        bytes
    }
}

/// Encode a record the way SQLite would, choosing the smallest integer type.
pub fn record(values: &[Value]) -> Vec<u8> {
    let mut types = Vec::new();
    let mut body = Vec::new();
    for v in values {
        match v {
            Value::Null => types.push(0),
            Value::Integer(0) => types.push(8),
            Value::Integer(1) => types.push(9),
            Value::Integer(n) => {
                let n = *n;
                let (t, size) = if i8::try_from(n).is_ok() {
                    (1, 1)
                } else if i16::try_from(n).is_ok() {
                    (2, 2)
                } else if (-(1 << 23)..(1 << 23)).contains(&n) {
                    (3, 3)
                } else if i32::try_from(n).is_ok() {
                    (4, 4)
                } else if (-(1 << 47)..(1 << 47)).contains(&n) {
                    (5, 6)
                } else {
                    (6, 8)
                };
                types.push(t);
                body.extend_from_slice(&n.to_be_bytes()[8 - size..]);
            }
            Value::Real(r) => {
                types.push(7);
                body.extend_from_slice(&r.to_be_bytes());
            }
            Value::Text(s) => {
                types.push(13 + 2 * s.len() as i64);
                body.extend_from_slice(s.as_bytes());
            }
            Value::Blob(b) => {
                types.push(12 + 2 * b.len() as i64);
                body.extend_from_slice(b);
            }
        }
    }
    let type_bytes: Vec<u8> = types.iter().flat_map(|t| varint(*t)).collect();
    // The header size counts its own varint; sizes here stay below 128.
    let mut hsize = type_bytes.len() + 1;
    if hsize > 127 {
        hsize += 1;
    }
    let mut out = varint(hsize as i64);
    out.extend(type_bytes);
    out.extend(body);
    out
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    TableLeaf,
    TableInterior,
    IndexLeaf,
    IndexInterior,
}

pub struct DbBuilder {
    pub page_size: usize,
    pages: Vec<Vec<u8>>,
    schema: Vec<Vec<u8>>,
}

impl DbBuilder {
    pub fn new(page_size: usize) -> DbBuilder {
        DbBuilder { page_size, pages: vec![vec![0; page_size]], schema: Vec::new() }
    }

    fn alloc(&mut self) -> u32 {
        self.pages.push(vec![0; self.page_size]);
        self.pages.len() as u32
    }

    /// Local payload bytes (+ overflow pointer) for a cell of this kind.
    fn local_payload(&mut self, payload: &[u8], table_leaf: bool) -> Vec<u8> {
        let u = self.page_size;
        let p = payload.len();
        let m = (u - 12) * 32 / 255 - 23;
        let x = if table_leaf { u - 35 } else { (u - 12) * 64 / 255 - 23 };
        if p <= x {
            return payload.to_vec();
        }
        let k = m + (p - m) % (u - 4);
        let local = if k <= x { k } else { m };
        let mut out = payload[..local].to_vec();
        let mut rest = &payload[local..];
        let mut prev: Option<u32> = None;
        let mut first = 0u32;
        while !rest.is_empty() {
            let n = rest.len().min(u - 4);
            let pg = self.alloc();
            self.pages[pg as usize - 1][4..4 + n].copy_from_slice(&rest[..n]);
            rest = &rest[n..];
            match prev {
                None => first = pg,
                Some(q) => self.pages[q as usize - 1][..4].copy_from_slice(&pg.to_be_bytes()),
            }
            prev = Some(pg);
        }
        out.extend_from_slice(&first.to_be_bytes());
        out
    }

    fn write_page(&mut self, pageno: u32, kind: Kind, cells: &[Vec<u8>], right: u32) {
        let base = if pageno == 1 { 100 } else { 0 };
        let size = self.page_size;
        let page = &mut self.pages[pageno as usize - 1];
        let interior = matches!(kind, Kind::TableInterior | Kind::IndexInterior);
        page[base] = match kind {
            Kind::IndexInterior => 0x02,
            Kind::TableInterior => 0x05,
            Kind::IndexLeaf => 0x0a,
            Kind::TableLeaf => 0x0d,
        };
        page[base + 3..base + 5].copy_from_slice(&(cells.len() as u16).to_be_bytes());
        let hdr = if interior {
            page[base + 8..base + 12].copy_from_slice(&right.to_be_bytes());
            12
        } else {
            8
        };
        let mut end = size;
        for (i, c) in cells.iter().enumerate() {
            end -= c.len();
            assert!(base + hdr + 2 * cells.len() <= end, "page overflow in test builder");
            page[end..end + c.len()].copy_from_slice(c);
            let at = base + hdr + 2 * i;
            page[at..at + 2].copy_from_slice(&(end as u16).to_be_bytes());
        }
        page[base + 5..base + 7].copy_from_slice(&(end as u16).to_be_bytes());
    }

    fn table_leaf_cell(&mut self, rowid: i64, payload: &[u8]) -> Vec<u8> {
        let mut c = varint(payload.len() as i64);
        c.extend(varint(rowid));
        c.extend(self.local_payload(payload, true));
        c
    }

    /// Build a table B-tree from `(rowid, record)` rows in ascending rowid
    /// order, with at most `per_leaf` rows per leaf; returns the root page.
    pub fn table(&mut self, rows: &[(i64, Vec<u8>)], per_leaf: usize) -> u32 {
        let chunks: Vec<&[(i64, Vec<u8>)]> = if rows.is_empty() {
            vec![rows]
        } else {
            rows.chunks(per_leaf).collect()
        };
        let mut leaves = Vec::new();
        for chunk in &chunks {
            let pg = self.alloc();
            let cells: Vec<Vec<u8>> =
                chunk.iter().map(|(r, p)| self.table_leaf_cell(*r, p)).collect();
            self.write_page(pg, Kind::TableLeaf, &cells, 0);
            leaves.push((pg, chunk.last().map(|r| r.0).unwrap_or(0)));
        }
        if leaves.len() == 1 {
            return leaves[0].0;
        }
        let root = self.alloc();
        let (&(last, _), init) = leaves.split_last().unwrap();
        let cells: Vec<Vec<u8>> = init
            .iter()
            .map(|(pg, key)| {
                let mut c = pg.to_be_bytes().to_vec();
                c.extend(varint(*key));
                c
            })
            .collect();
        self.write_page(root, Kind::TableInterior, &cells, last);
        root
    }

    /// Build an index B-tree from records sorted in index order. Entries are
    /// grouped `per_leaf` to a leaf with the separator entry stored in the
    /// (single) interior root page, as SQLite does.
    pub fn index(&mut self, entries: &[Vec<u8>], per_leaf: usize) -> u32 {
        if entries.len() <= per_leaf {
            let pg = self.alloc();
            let cells: Vec<Vec<u8>> = entries
                .iter()
                .map(|e| {
                    let mut c = varint(e.len() as i64);
                    c.extend(self.local_payload(e, false));
                    c
                })
                .collect();
            self.write_page(pg, Kind::IndexLeaf, &cells, 0);
            return pg;
        }
        let mut i = 0;
        let mut interior_cells = Vec::new();
        let mut right = 0;
        while i < entries.len() {
            let end = (i + per_leaf).min(entries.len());
            let pg = self.alloc();
            let cells: Vec<Vec<u8>> = entries[i..end]
                .iter()
                .map(|e| {
                    let mut c = varint(e.len() as i64);
                    c.extend(self.local_payload(e, false));
                    c
                })
                .collect();
            self.write_page(pg, Kind::IndexLeaf, &cells, 0);
            if end < entries.len() {
                // Promote the next entry as the separator.
                let sep = &entries[end];
                let mut c = pg.to_be_bytes().to_vec();
                c.extend(varint(sep.len() as i64));
                c.extend(self.local_payload(sep, false));
                interior_cells.push(c);
                i = end + 1;
            } else {
                right = pg;
                i = end;
            }
        }
        let root = self.alloc();
        self.write_page(root, Kind::IndexInterior, &interior_cells, right);
        root
    }

    /// Register a row of `sqlite_schema`.
    pub fn schema_row(&mut self, kind: &str, name: &str, tbl: &str, root: u32, sql: Option<&str>) {
        let rec = record(&[
            Value::Text(kind.into()),
            Value::Text(name.into()),
            Value::Text(tbl.into()),
            Value::Integer(i64::from(root)),
            sql.map(|s| Value::Text(s.into())).unwrap_or(Value::Null),
        ]);
        self.schema.push(rec);
    }

    /// Write page 1 and return the finished file.
    pub fn finish(mut self) -> Vec<u8> {
        let rows: Vec<(i64, Vec<u8>)> = std::mem::take(&mut self.schema)
            .into_iter()
            .enumerate()
            .map(|(i, r)| (i as i64 + 1, r))
            .collect();
        let cells: Vec<Vec<u8>> = rows.iter().map(|(r, p)| self.table_leaf_cell(*r, p)).collect();
        self.write_page(1, Kind::TableLeaf, &cells, 0);
        let n = self.pages.len() as u32;
        let ps = self.page_size;
        let p1 = &mut self.pages[0];
        p1[..16].copy_from_slice(b"SQLite format 3\0");
        p1[16..18].copy_from_slice(&(if ps == 65536 { 1u16 } else { ps as u16 }).to_be_bytes());
        p1[18] = 1;
        p1[19] = 1;
        p1[28..32].copy_from_slice(&n.to_be_bytes());
        p1[56..60].copy_from_slice(&1u32.to_be_bytes());
        self.pages.concat()
    }
}

pub fn int(n: i64) -> Value {
    Value::Integer(n)
}
pub fn text(s: &str) -> Value {
    Value::Text(s.to_string())
}
