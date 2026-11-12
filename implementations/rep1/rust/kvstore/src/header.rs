//! The header page (page 1) and the index directory (spec §7, §8).

use crate::error::{Error, Result};
use crate::{MAX_INDEXES, PAGE_SIZE};

/// A raw 1024-byte page image.
pub type Page = [u8; PAGE_SIZE];

/// Bytes of one directory slot.
const SLOT_SIZE: usize = 48;
/// Offset of the directory in the header page.
const DIR_OFFSET: usize = 128;

/// One slot of the index directory.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IndexSlot {
    /// Whether the slot describes a live index.
    pub live: bool,
    /// The indexed path text (empty for an unused slot).
    pub path: String,
    /// Root page of the index tree, `0` when empty.
    pub root: u32,
    /// Number of entries in the index.
    pub entries: u32,
}

/// The decoded contents of page 1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Header {
    /// Number of pages in the database.
    pub page_count: u32,
    /// First page of the free list, `0` if empty.
    pub freelist_head: u32,
    /// Number of pages on the free list.
    pub freelist_count: u32,
    /// Root of the primary tree, `0` if the store is empty.
    pub primary_root: u32,
    /// Number of documents.
    pub primary_count: u32,
    /// Number of transactions committed over the database's lifetime.
    pub commit_counter: u64,
    /// The index directory.
    pub slots: [IndexSlot; MAX_INDEXES],
}

fn be32(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

impl Header {
    /// The header of a fresh database (spec §7.3).
    pub fn fresh() -> Header {
        Header {
            page_count: 1,
            freelist_head: 0,
            freelist_count: 0,
            primary_root: 0,
            primary_count: 0,
            commit_counter: 0,
            slots: Default::default(),
        }
    }

    /// Number of live index slots.
    pub fn index_count(&self) -> u32 {
        self.slots.iter().filter(|s| s.live).count() as u32
    }

    /// Decodes page 1.
    pub fn decode(page: &[u8]) -> Result<Header> {
        if page.len() < PAGE_SIZE || &page[0..8] != crate::MAGIC {
            return Err(Error::Corrupt);
        }
        let mut h = Header::fresh();
        h.page_count = be32(page, 12);
        h.freelist_head = be32(page, 16);
        h.freelist_count = be32(page, 20);
        h.primary_root = be32(page, 24);
        h.primary_count = be32(page, 28);
        h.commit_counter = u64::from_be_bytes(page[32..40].try_into().map_err(|_| Error::Corrupt)?);
        for (i, slot) in h.slots.iter_mut().enumerate() {
            let s = &page[DIR_OFFSET + SLOT_SIZE * i..DIR_OFFSET + SLOT_SIZE * (i + 1)];
            if s[0] == 1 {
                let len = (s[1] as usize).min(30);
                slot.live = true;
                slot.path = String::from_utf8_lossy(&s[2..2 + len]).into_owned();
                slot.root = be32(s, 32);
                slot.entries = be32(s, 36);
            }
        }
        Ok(h)
    }

    /// Encodes the canonical 1024-byte page 1.
    pub fn encode(&self) -> Page {
        let mut p = [0u8; PAGE_SIZE];
        p[0..8].copy_from_slice(crate::MAGIC);
        p[8..10].copy_from_slice(&1u16.to_be_bytes());
        p[10..12].copy_from_slice(&(PAGE_SIZE as u16).to_be_bytes());
        p[12..16].copy_from_slice(&self.page_count.to_be_bytes());
        p[16..20].copy_from_slice(&self.freelist_head.to_be_bytes());
        p[20..24].copy_from_slice(&self.freelist_count.to_be_bytes());
        p[24..28].copy_from_slice(&self.primary_root.to_be_bytes());
        p[28..32].copy_from_slice(&self.primary_count.to_be_bytes());
        p[32..40].copy_from_slice(&self.commit_counter.to_be_bytes());
        p[40..44].copy_from_slice(&self.index_count().to_be_bytes());
        for (i, slot) in self.slots.iter().enumerate() {
            if !slot.live {
                continue;
            }
            let s = &mut p[DIR_OFFSET + SLOT_SIZE * i..DIR_OFFSET + SLOT_SIZE * (i + 1)];
            s[0] = 1;
            s[1] = slot.path.len() as u8;
            s[2..2 + slot.path.len()].copy_from_slice(slot.path.as_bytes());
            s[32..36].copy_from_slice(&slot.root.to_be_bytes());
            s[36..40].copy_from_slice(&slot.entries.to_be_bytes());
        }
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_page_matches_the_spec() {
        let p = Header::fresh().encode();
        assert_eq!(&p[0..16], b"TESSERA1\x00\x01\x04\x00\x00\x00\x00\x01");
        assert!(p[16..].iter().all(|&b| b == 0));
    }

    #[test]
    fn round_trip_with_an_index() {
        let mut h = Header::fresh();
        h.page_count = 4;
        h.primary_root = 2;
        h.primary_count = 1;
        h.commit_counter = 2;
        h.slots[0] = IndexSlot { live: true, path: "age".into(), root: 4, entries: 1 };
        let p = h.encode();
        assert_eq!(&p[128..134], &[1, 3, b'a', b'g', b'e', 0]);
        assert_eq!(&p[160..168], &[0, 0, 0, 4, 0, 0, 0, 1]);
        assert_eq!(p[43], 1);
        assert_eq!(Header::decode(&p).unwrap(), h);
    }
}
