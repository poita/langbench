//! Overflow chains for documents longer than [`MAX_INLINE`] bytes (spec §9).

use crate::btree::Cell;
use crate::error::{Error, Result};
use crate::pager::Pager;
use crate::{MAX_INLINE, OVF_PAYLOAD, PAGE_SIZE};

const OVERFLOW_TYPE: u8 = 3;

/// Builds the primary leaf cell for `key` holding the serialised document
/// `doc`, allocating and writing its overflow chain (first chunk first).
pub fn build_cell(pager: &mut Pager, key: &[u8], doc: &[u8]) -> Cell {
    let inline_len = doc.len().min(MAX_INLINE);
    let rest = &doc[inline_len..];
    let mut overflow = 0;
    if !rest.is_empty() {
        let chunks: Vec<&[u8]> = rest.chunks(OVF_PAYLOAD).collect();
        let pages: Vec<u32> = chunks.iter().map(|_| pager.allocate()).collect();
        for (i, chunk) in chunks.iter().enumerate() {
            let next = pages.get(i + 1).copied().unwrap_or(0);
            let mut page = [0u8; PAGE_SIZE];
            page[0] = OVERFLOW_TYPE;
            page[4..8].copy_from_slice(&next.to_be_bytes());
            page[8..10].copy_from_slice(&(chunk.len() as u16).to_be_bytes());
            page[12..12 + chunk.len()].copy_from_slice(chunk);
            pager.write_page(pages[i], &page);
        }
        overflow = pages[0];
    }
    Cell {
        key: key.to_vec(),
        child: 0,
        doc_len: doc.len() as u32,
        overflow,
        inline: doc[..inline_len].to_vec(),
    }
}

/// Reassembles the serialised document of a primary leaf cell.
pub fn read_document(pager: &Pager, cell: &Cell) -> Result<Vec<u8>> {
    let mut doc = cell.inline.clone();
    let mut next = cell.overflow;
    while next != 0 {
        let page = pager.read_page(next);
        let len = u16::from_be_bytes([page[8], page[9]]) as usize;
        if page[0] != OVERFLOW_TYPE || len > OVF_PAYLOAD || doc.len() > crate::MAX_DOC {
            return Err(Error::Corrupt);
        }
        doc.extend_from_slice(&page[12..12 + len]);
        next = u32::from_be_bytes([page[4], page[5], page[6], page[7]]);
    }
    if doc.len() != cell.doc_len as usize {
        return Err(Error::Corrupt);
    }
    Ok(doc)
}

/// Frees an overflow chain in chain order (first chunk first), so the last
/// page of the chain ends up at the head of the free list.
pub fn free_chain(pager: &mut Pager, first: u32) {
    let mut next = first;
    while next != 0 {
        let page = pager.read_page(next);
        let following = u32::from_be_bytes([page[4], page[5], page[6], page[7]]);
        pager.free(next);
        next = following;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::Header;
    use crate::wal;
    use std::collections::BTreeMap;

    fn pager() -> Pager {
        Pager::new(Header::fresh().encode().to_vec(), BTreeMap::new(), wal::header_bytes().to_vec()).unwrap()
    }

    #[test]
    fn spec_free_then_allocate_example() {
        let mut p = pager();
        let doc: Vec<u8> = (0..2005u32).map(|i| (i % 251) as u8).collect();
        let cell = build_cell(&mut p, b"a", &doc);
        assert_eq!(cell.overflow, 2);
        assert_eq!(p.header.page_count, 3);
        assert_eq!(read_document(&p, &cell).unwrap(), doc);
        free_chain(&mut p, cell.overflow);
        assert_eq!((p.header.freelist_head, p.header.freelist_count), (3, 2));
        let again = build_cell(&mut p, b"a", &doc);
        assert_eq!(again.overflow, 3);
        assert_eq!(p.header.page_count, 3);
        assert_eq!(read_document(&p, &again).unwrap(), doc);
    }

    #[test]
    fn short_documents_stay_inline() {
        let mut p = pager();
        let cell = build_cell(&mut p, b"k", &[7u8; 192]);
        assert_eq!(cell.overflow, 0);
        assert_eq!(cell.inline.len(), 192);
        assert_eq!(p.header.page_count, 1);
        let cell = build_cell(&mut p, b"k", &[7u8; 193]);
        assert_ne!(cell.overflow, 0);
        assert_eq!(p.header.page_count, 2);
    }
}
