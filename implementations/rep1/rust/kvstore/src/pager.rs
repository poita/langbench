//! The page store: the main file, the log overlay, the open transaction's
//! dirty pages, the free list, commit and checkpoint (spec §10, §13, §15.6).

use std::collections::BTreeMap;

use crate::header::{Header, Page};
use crate::wal;
use crate::{PAGE_SIZE, WAL_LIMIT};

/// Identifies one of the B+trees of the database.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TreeId {
    /// The primary tree, keyed by document key.
    Primary,
    /// The tree of the index in the given directory slot.
    Index(usize),
}

/// What a commit did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CommitInfo {
    /// The new `commit_counter`.
    pub txn_id: u64,
    /// Number of page images appended to the log.
    pub frames: u32,
}

/// Page-level storage with transactional semantics.
///
/// Reads go through the dirty set, then the log overlay, then the main file.
/// The header fields (the contents of page 1) are kept decoded in
/// [`Pager::header`]; they are re-encoded into page 1 at commit.
pub struct Pager {
    main: Vec<u8>,
    overlay: BTreeMap<u32, Page>,
    dirty: BTreeMap<u32, Page>,
    wal: Vec<u8>,
    /// The engine's current view of the header page, including uncommitted
    /// changes.
    pub header: Header,
    committed: Header,
}

impl Pager {
    /// Creates a pager over a main file image and a recovered overlay and log.
    ///
    /// `main` must be a whole number of pages (at least one) and `wal` must
    /// start with a valid log header.
    pub fn new(main: Vec<u8>, overlay: BTreeMap<u32, Page>, wal: Vec<u8>) -> crate::Result<Pager> {
        let page1: &[u8] = match overlay.get(&1) {
            Some(p) => p,
            None => &main[..PAGE_SIZE],
        };
        let header = Header::decode(page1)?;
        Ok(Pager { main, overlay, dirty: BTreeMap::new(), wal, committed: header.clone(), header })
    }

    /// Bytes of the main file.
    pub fn main_bytes(&self) -> &[u8] {
        &self.main
    }

    /// Bytes of the log.
    pub fn wal_bytes(&self) -> &[u8] {
        &self.wal
    }

    /// Current size of the log in bytes.
    pub fn wal_len(&self) -> usize {
        self.wal.len()
    }

    /// Reads a page through the dirty set, the overlay and the main file.
    pub fn read_page(&self, p: u32) -> Page {
        if let Some(img) = self.dirty.get(&p) {
            return *img;
        }
        if let Some(img) = self.overlay.get(&p) {
            return *img;
        }
        let off = (p as usize).saturating_sub(1) * PAGE_SIZE;
        if p >= 1 && off + PAGE_SIZE <= self.main.len() {
            let mut page = [0u8; PAGE_SIZE];
            page.copy_from_slice(&self.main[off..off + PAGE_SIZE]);
            return page;
        }
        [0u8; PAGE_SIZE]
    }

    /// Stores a new image of page `p` in the open transaction.
    pub fn write_page(&mut self, p: u32, image: &Page) {
        self.dirty.insert(p, *image);
    }

    /// Allocates a page: pops the free list, else extends the file.
    pub fn allocate(&mut self) -> u32 {
        if self.header.freelist_head != 0 {
            let p = self.header.freelist_head;
            let page = self.read_page(p);
            self.header.freelist_head = u32::from_be_bytes([page[4], page[5], page[6], page[7]]);
            self.header.freelist_count -= 1;
            p
        } else {
            self.header.page_count += 1;
            self.header.page_count
        }
    }

    /// Pushes page `p` onto the free list.
    pub fn free(&mut self, p: u32) {
        let mut page = [0u8; PAGE_SIZE];
        page[4..8].copy_from_slice(&self.header.freelist_head.to_be_bytes());
        self.write_page(p, &page);
        self.header.freelist_head = p;
        self.header.freelist_count += 1;
    }

    /// Root page of `tree` (`0` when empty).
    pub fn root(&self, tree: TreeId) -> u32 {
        match tree {
            TreeId::Primary => self.header.primary_root,
            TreeId::Index(s) => self.header.slots[s].root,
        }
    }

    /// Sets the root page of `tree`.
    pub fn set_root(&mut self, tree: TreeId, root: u32) {
        match tree {
            TreeId::Primary => self.header.primary_root = root,
            TreeId::Index(s) => self.header.slots[s].root = root,
        }
    }

    /// Commits the dirty pages: bumps `commit_counter`, appends the page
    /// images in ascending page order and a commit record to the log, and
    /// checkpoints if the log reached [`WAL_LIMIT`].
    pub fn commit(&mut self) -> CommitInfo {
        self.header.commit_counter += 1;
        let txn_id = self.header.commit_counter;
        self.dirty.insert(1, self.header.encode());
        let frames = self.dirty.len() as u32;
        for (p, img) in &self.dirty {
            wal::append_page_image(&mut self.wal, txn_id, *p, img);
        }
        wal::append_commit(&mut self.wal, txn_id, frames);
        let dirty = std::mem::take(&mut self.dirty);
        self.overlay.extend(dirty);
        self.committed = self.header.clone();
        if self.wal.len() >= WAL_LIMIT {
            self.checkpoint();
        }
        CommitInfo { txn_id, frames }
    }

    /// Discards the dirty pages and restores the committed header.
    pub fn rollback(&mut self) {
        self.dirty.clear();
        self.header = self.committed.clone();
    }

    /// Copies the overlay into the main file and resets the log. Returns the
    /// number of pages copied. Must not be called with dirty pages.
    pub fn checkpoint(&mut self) -> usize {
        let n = self.overlay.len();
        let total = self.committed.page_count as usize * PAGE_SIZE;
        self.main.resize(total, 0);
        for (p, img) in &self.overlay {
            let off = (*p as usize - 1) * PAGE_SIZE;
            if off + PAGE_SIZE <= total {
                self.main[off..off + PAGE_SIZE].copy_from_slice(img);
            }
        }
        self.overlay.clear();
        self.wal = wal::header_bytes().to_vec();
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> Pager {
        Pager::new(Header::fresh().encode().to_vec(), BTreeMap::new(), wal::header_bytes().to_vec()).unwrap()
    }

    #[test]
    fn allocation_and_free_list_are_lifo() {
        let mut p = fresh();
        assert_eq!(p.allocate(), 2);
        assert_eq!(p.allocate(), 3);
        p.free(2);
        p.free(3);
        assert_eq!(p.header.freelist_count, 2);
        assert_eq!(p.allocate(), 3);
        assert_eq!(p.allocate(), 2);
        assert_eq!(p.allocate(), 4);
    }

    #[test]
    fn rollback_restores_the_header() {
        let mut p = fresh();
        p.allocate();
        p.rollback();
        assert_eq!(p.header.page_count, 1);
    }

    #[test]
    fn commit_appends_and_checkpoint_resets() {
        let mut p = fresh();
        let r = p.allocate();
        p.write_page(r, &[1u8; PAGE_SIZE]);
        let info = p.commit();
        assert_eq!((info.txn_id, info.frames), (1, 2));
        assert_eq!(p.wal_len(), 32 + 2 * 1048 + 24);
        assert_eq!(p.read_page(r)[0], 1);
        assert_eq!(p.checkpoint(), 2);
        assert_eq!(p.wal_len(), 32);
        assert_eq!(p.main_bytes().len(), 2048);
        assert_eq!(p.read_page(r)[0], 1);
    }
}
