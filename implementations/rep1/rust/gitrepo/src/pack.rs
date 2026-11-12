//! Pack index (version 2) lookup and pack entry decoding.

use crate::error::{Error, Result};
use crate::inflate::zlib_decompress;
use crate::object::Kind;
use crate::oid::ObjectId;

const IDX_HEADER: usize = 8;
const FANOUT_BYTES: usize = 1024;
const IDS_START: usize = IDX_HEADER + FANOUT_BYTES;

/// A parsed `.idx` file, version 2.
pub struct PackIndex {
    data: Vec<u8>,
    fanout: [u32; 256],
    count: usize,
}

impl PackIndex {
    /// Validates and wraps the bytes of an index file.
    pub fn parse(data: Vec<u8>) -> Result<PackIndex> {
        if data.len() < IDS_START + 40 || data[..4] != [0xff, b't', b'O', b'c'] {
            return Err(Error::corrupt("not a pack index"));
        }
        if u32::from_be_bytes(data[4..8].try_into().unwrap()) != 2 {
            return Err(Error::corrupt("unsupported pack index version"));
        }
        let mut fanout = [0u32; 256];
        let mut prev = 0;
        for (i, f) in fanout.iter_mut().enumerate() {
            let o = IDX_HEADER + 4 * i;
            *f = u32::from_be_bytes(data[o..o + 4].try_into().unwrap());
            if *f < prev {
                return Err(Error::corrupt("pack index fanout not monotonic"));
            }
            prev = *f;
        }
        let count = fanout[255] as usize;
        if data.len() < IDS_START + 28 * count + 40 {
            return Err(Error::corrupt("pack index truncated"));
        }
        Ok(PackIndex { data, fanout, count })
    }

    /// Number of objects in the index (`fanout[255]`).
    pub fn len(&self) -> usize {
        self.count
    }

    /// True if the index lists no objects.
    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    /// The id at sorted position `i`.
    pub fn id_at(&self, i: usize) -> ObjectId {
        let o = IDS_START + 20 * i;
        ObjectId::from_slice(&self.data[o..o + 20]).expect("20 bytes")
    }

    /// The first sorted position whose id is `>= key`.
    pub fn lower_bound(&self, key: &[u8; 20]) -> usize {
        let b = key[0] as usize;
        let mut lo = if b == 0 { 0 } else { self.fanout[b - 1] as usize };
        let mut hi = self.fanout[b] as usize;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let o = IDS_START + 20 * mid;
            if self.data[o..o + 20] < key[..] {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    /// Looks up an id and returns its pack offset.
    pub fn find(&self, id: &ObjectId) -> Option<Result<u64>> {
        let i = self.lower_bound(id.as_bytes());
        if i < self.count && self.id_at(i) == *id {
            Some(self.offset_at(i))
        } else {
            None
        }
    }

    /// True if the index lists `id`.
    pub fn contains(&self, id: &ObjectId) -> bool {
        let i = self.lower_bound(id.as_bytes());
        i < self.count && self.id_at(i) == *id
    }

    /// The pack offset of the object at sorted position `i`.
    pub fn offset_at(&self, i: usize) -> Result<u64> {
        let o = IDS_START + 24 * self.count + 4 * i;
        let v = u32::from_be_bytes(self.data[o..o + 4].try_into().unwrap());
        if v & 0x8000_0000 == 0 {
            return Ok(v as u64);
        }
        let idx = (v & 0x7fff_ffff) as usize;
        let start = IDS_START + 28 * self.count + 8 * idx;
        let bytes = self
            .data
            .get(start..start + 8)
            .ok_or_else(|| Error::corrupt("64-bit offset out of range"))?;
        Ok(u64::from_be_bytes(bytes.try_into().unwrap()))
    }
}

/// One object as stored in a pack, before delta resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackEntry {
    /// A complete object.
    Base { kind: Kind, data: Vec<u8> },
    /// A delta against the object at `base_offset` in the same pack.
    OfsDelta { base_offset: u64, delta: Vec<u8> },
    /// A delta against the object with id `base`, anywhere in the repository.
    RefDelta { base: ObjectId, delta: Vec<u8> },
}

/// An index together with the bytes of its pack.
pub struct Pack {
    pub index: PackIndex,
    data: Vec<u8>,
}

impl Pack {
    /// Pairs an index with pack bytes, validating the pack header.
    pub fn new(index: PackIndex, data: Vec<u8>) -> Result<Pack> {
        if data.len() < 32
            || &data[..4] != b"PACK"
            || u32::from_be_bytes(data[4..8].try_into().unwrap()) != 2
        {
            return Err(Error::corrupt("not a version 2 packfile"));
        }
        Ok(Pack { index, data })
    }

    /// Decodes the entry that starts at `offset`.
    pub fn entry_at(&self, offset: u64) -> Result<PackEntry> {
        let limit = self.data.len() - 20;
        if offset < 12 || offset >= limit as u64 {
            return Err(Error::corrupt("pack offset out of range"));
        }
        let body = &self.data[..limit];
        let mut pos = offset as usize;
        let first = body[pos];
        pos += 1;
        let ty = (first >> 4) & 7;
        let mut more = first & 0x80 != 0;
        let mut guard = 0;
        while more {
            let b = *body.get(pos).ok_or_else(|| Error::corrupt("truncated pack header"))?;
            pos += 1;
            more = b & 0x80 != 0;
            guard += 1;
            if guard > 10 {
                return Err(Error::corrupt("pack object size too long"));
            }
        }
        match ty {
            1..=4 => {
                let kind = [Kind::Commit, Kind::Tree, Kind::Blob, Kind::Tag][ty as usize - 1];
                let data = zlib_decompress(&body[pos..])?.data;
                Ok(PackEntry::Base { kind, data })
            }
            6 => {
                let mut b = *body.get(pos).ok_or_else(|| Error::corrupt("truncated pack header"))?;
                pos += 1;
                let mut v = (b & 0x7f) as u64;
                while b & 0x80 != 0 {
                    b = *body.get(pos).ok_or_else(|| Error::corrupt("truncated pack header"))?;
                    pos += 1;
                    if v >= 1 << 56 {
                        return Err(Error::corrupt("delta base offset too large"));
                    }
                    v = ((v + 1) << 7) | (b & 0x7f) as u64;
                }
                let base_offset = offset
                    .checked_sub(v)
                    .filter(|&o| o >= 12)
                    .ok_or_else(|| Error::corrupt("delta base offset out of range"))?;
                let delta = zlib_decompress(&body[pos..])?.data;
                Ok(PackEntry::OfsDelta { base_offset, delta })
            }
            7 => {
                let base = body
                    .get(pos..pos + 20)
                    .and_then(ObjectId::from_slice)
                    .ok_or_else(|| Error::corrupt("truncated pack header"))?;
                let delta = zlib_decompress(&body[pos + 20..])?.data;
                Ok(PackEntry::RefDelta { base, delta })
            }
            _ => Err(Error::corrupt("invalid pack object type")),
        }
    }
}
