//! The write-ahead log: record encoding and the recovery scan (spec §15, §16).

use std::collections::BTreeMap;

use crate::crc::{crc32, Crc32};
use crate::header::Page;
use crate::{PAGE_SIZE, WAL_MAGIC};

/// Bytes of the log header.
pub const WAL_HEADER_SIZE: usize = 32;
/// Bytes of a record header.
pub const RECORD_HEADER_SIZE: usize = 24;

const TYPE_PAGE: u8 = 1;
const TYPE_COMMIT: u8 = 2;

/// The 32-byte log header.
pub fn header_bytes() -> [u8; WAL_HEADER_SIZE] {
    let mut h = [0u8; WAL_HEADER_SIZE];
    h[0..8].copy_from_slice(WAL_MAGIC);
    h[8..10].copy_from_slice(&1u16.to_be_bytes());
    h[10..12].copy_from_slice(&(PAGE_SIZE as u16).to_be_bytes());
    let crc = crc32(&h[0..28]);
    h[28..32].copy_from_slice(&crc.to_be_bytes());
    h
}

/// Whether `bytes` starts with a valid log header (spec §16.2).
pub fn header_valid(bytes: &[u8]) -> bool {
    bytes.len() >= WAL_HEADER_SIZE && bytes[..WAL_HEADER_SIZE] == header_bytes()
}

fn record(kind: u8, txn_id: u64, arg: u32, payload: &[u8], out: &mut Vec<u8>) {
    let mut h = [0u8; RECORD_HEADER_SIZE];
    h[0] = kind;
    h[4..12].copy_from_slice(&txn_id.to_be_bytes());
    h[12..16].copy_from_slice(&arg.to_be_bytes());
    h[16..20].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    let mut c = Crc32::new();
    c.update(&h[0..20]);
    c.update(payload);
    h[20..24].copy_from_slice(&c.finish().to_be_bytes());
    out.extend_from_slice(&h);
    out.extend_from_slice(payload);
}

/// Appends a page image record.
pub fn append_page_image(out: &mut Vec<u8>, txn_id: u64, page_no: u32, image: &Page) {
    record(TYPE_PAGE, txn_id, page_no, image, out);
}

/// Appends a commit record for a transaction of `frames` page images.
pub fn append_commit(out: &mut Vec<u8>, txn_id: u64, frames: u32) {
    record(TYPE_COMMIT, txn_id, frames, &[], out);
}

/// The outcome of scanning a log (spec §16.3).
pub struct Recovered {
    /// Newest committed image of every page that appears in a committed
    /// transaction.
    pub overlay: BTreeMap<u32, Page>,
    /// Offset just past the last accepted commit record (32 if none).
    pub valid_end: usize,
}

/// Scans a log whose header has already been validated, replaying committed
/// transactions only.
pub fn scan(bytes: &[u8]) -> Recovered {
    let mut overlay = BTreeMap::new();
    let mut valid_end = WAL_HEADER_SIZE;
    let mut off = WAL_HEADER_SIZE;
    // The open group: transaction id and its page images so far.
    let mut group: Option<(u64, Vec<(u32, Page)>)> = None;
    loop {
        let rem = bytes.len() - off;
        if rem < RECORD_HEADER_SIZE {
            break;
        }
        let h = &bytes[off..off + RECORD_HEADER_SIZE];
        let kind = h[0];
        let txn_id = u64::from_be_bytes(h[4..12].try_into().unwrap());
        let arg = u32::from_be_bytes(h[12..16].try_into().unwrap());
        let payload_len = u32::from_be_bytes(h[16..20].try_into().unwrap()) as usize;
        let crc = u32::from_be_bytes(h[20..24].try_into().unwrap());
        let shape_ok = (kind == TYPE_PAGE || kind == TYPE_COMMIT)
            && h[1..4] == [0, 0, 0]
            && payload_len == if kind == TYPE_PAGE { PAGE_SIZE } else { 0 }
            && arg >= 1
            && rem >= RECORD_HEADER_SIZE + payload_len;
        if !shape_ok {
            break;
        }
        let payload = &bytes[off + RECORD_HEADER_SIZE..off + RECORD_HEADER_SIZE + payload_len];
        let mut c = Crc32::new();
        c.update(&h[0..20]);
        c.update(payload);
        if c.finish() != crc {
            break;
        }
        if kind == TYPE_PAGE {
            match &mut group {
                Some((id, _)) if *id != txn_id => break,
                Some((_, images)) => images.push((arg, payload.try_into().unwrap())),
                None => group = Some((txn_id, vec![(arg, payload.try_into().unwrap())])),
            }
            off += RECORD_HEADER_SIZE + PAGE_SIZE;
        } else {
            match group.take() {
                Some((id, images)) if id == txn_id && images.len() == arg as usize => {
                    for (p, img) in images {
                        overlay.insert(p, img);
                    }
                    off += RECORD_HEADER_SIZE;
                    valid_end = off;
                }
                _ => break,
            }
        }
    }
    Recovered { overlay, valid_end }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_matches_the_spec() {
        let h = header_bytes();
        assert_eq!(&h[0..8], b"TESSWAL1");
        assert_eq!(&h[28..32], &[0x51, 0xe7, 0x21, 0x53]);
        assert!(header_valid(&h));
        let mut bad = h;
        bad[12] = 1;
        assert!(!header_valid(&bad));
        assert!(!header_valid(&h[..31]));
    }

    #[test]
    fn commit_record_example() {
        let mut out = Vec::new();
        append_commit(&mut out, 1, 2);
        assert_eq!(out, [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0xa8, 0xa0, 0xaa, 0x22]);
    }

    #[test]
    fn scan_keeps_only_committed_transactions() {
        let mut log = header_bytes().to_vec();
        let mut page = [0u8; PAGE_SIZE];
        page[0] = 7;
        append_page_image(&mut log, 1, 1, &page);
        append_page_image(&mut log, 1, 2, &page);
        append_commit(&mut log, 1, 2);
        let end = log.len();
        append_page_image(&mut log, 2, 3, &page);
        let r = scan(&log);
        assert_eq!(r.valid_end, end);
        assert_eq!(r.overlay.len(), 2);
        // A commit with the wrong frame count is not accepted.
        let mut log2 = header_bytes().to_vec();
        append_page_image(&mut log2, 1, 1, &page);
        append_commit(&mut log2, 1, 2);
        assert_eq!(scan(&log2).valid_end, WAL_HEADER_SIZE);
        // Truncation inside a record.
        assert_eq!(scan(&log[..end - 1]).valid_end, WAL_HEADER_SIZE);
    }
}
