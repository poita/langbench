//! The database file held in memory: header validation and page access.

use crate::error::{Error, Result};
use std::path::Path;

/// An in-memory SQLite database file.
#[derive(Debug)]
pub struct Database {
    data: Vec<u8>,
    page_size: usize,
    usable: usize,
}

impl Database {
    /// Read the file at `path` into memory and validate its header.
    pub fn open(path: impl AsRef<Path>) -> Result<Database> {
        Database::from_bytes(std::fs::read(path)?)
    }

    /// Wrap the bytes of a database file, validating the 100-byte header.
    pub fn from_bytes(data: Vec<u8>) -> Result<Database> {
        if data.len() < 100 || &data[..16] != b"SQLite format 3\0" {
            return Err(Error::corrupt("not a SQLite 3 database"));
        }
        let raw = usize::from(u16::from_be_bytes([data[16], data[17]]));
        let page_size = if raw == 1 { 65536 } else { raw };
        if !(512..=65536).contains(&page_size) || !page_size.is_power_of_two() {
            return Err(Error::corrupt("invalid page size"));
        }
        let reserved = usize::from(data[20]);
        let usable = page_size - reserved;
        if usable < 480 {
            return Err(Error::corrupt("usable page size too small"));
        }
        if data.len() < page_size {
            return Err(Error::corrupt("file shorter than one page"));
        }
        Ok(Database { data, page_size, usable })
    }

    /// Page size in bytes.
    pub fn page_size(&self) -> usize {
        self.page_size
    }

    /// Usable size `U`: page size minus the reserved bytes at the end of a page.
    pub fn usable_size(&self) -> usize {
        self.usable
    }

    /// Number of whole pages present in the file.
    pub fn page_count(&self) -> usize {
        self.data.len() / self.page_size
    }

    /// Total size of the file in bytes.
    pub fn len(&self) -> usize {
        self.data.len()
    }

    /// `true` if the file is empty (never the case for a validated database).
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// The bytes of page `n` (1-based).
    pub fn page(&self, n: u32) -> Result<&[u8]> {
        let n = n as usize;
        if n == 0 || n > self.page_count() {
            return Err(Error::corrupt(format!("page {n} out of range")));
        }
        let start = (n - 1) * self.page_size;
        Ok(&self.data[start..start + self.page_size])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header(page_size: u16, pages: usize) -> Vec<u8> {
        let mut d = vec![0u8; page_size as usize * pages];
        d[..16].copy_from_slice(b"SQLite format 3\0");
        d[16..18].copy_from_slice(&page_size.to_be_bytes());
        d
    }

    #[test]
    fn opens_and_slices_pages() {
        let db = Database::from_bytes(header(512, 3)).unwrap();
        assert_eq!(db.page_size(), 512);
        assert_eq!(db.usable_size(), 512);
        assert_eq!(db.page_count(), 3);
        assert_eq!(db.page(3).unwrap().len(), 512);
        assert!(db.page(0).is_err());
        assert!(db.page(4).is_err());
    }

    #[test]
    fn page_size_one_means_65536() {
        let mut d = vec![0u8; 65536];
        d[..16].copy_from_slice(b"SQLite format 3\0");
        d[16..18].copy_from_slice(&1u16.to_be_bytes());
        assert_eq!(Database::from_bytes(d).unwrap().page_size(), 65536);
    }

    #[test]
    fn rejects_bad_magic() {
        let mut d = header(512, 1);
        d[0] = b'X';
        assert!(Database::from_bytes(d).is_err());
        assert!(Database::from_bytes(vec![]).is_err());
    }
}
