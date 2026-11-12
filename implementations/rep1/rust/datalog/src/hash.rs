//! A small, fast, non-cryptographic hasher (FxHash-style) for integer keys.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

const K: u64 = 0x517c_c1b7_2722_0a95;

/// Multiply-rotate hasher. Not DoS resistant; inputs here are trusted
/// tuples of interned constants.
#[derive(Default, Clone, Copy)]
pub struct FxHasher {
    hash: u64,
}

impl FxHasher {
    #[inline]
    fn add(&mut self, word: u64) {
        self.hash = (self.hash.rotate_left(5) ^ word).wrapping_mul(K);
    }
}

impl Hasher for FxHasher {
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        let mut chunks = bytes.chunks_exact(8);
        for c in &mut chunks {
            self.add(u64::from_le_bytes(c.try_into().unwrap()));
        }
        for &b in chunks.remainder() {
            self.add(u64::from(b));
        }
    }

    #[inline]
    fn write_u32(&mut self, i: u32) {
        self.add(u64::from(i));
    }

    #[inline]
    fn write_u64(&mut self, i: u64) {
        self.add(i);
    }

    #[inline]
    fn write_usize(&mut self, i: usize) {
        self.add(i as u64);
    }

    #[inline]
    fn finish(&self) -> u64 {
        self.hash.rotate_left(26)
    }
}

/// `HashMap` using [`FxHasher`].
pub type FxHashMap<K, V> = HashMap<K, V, BuildHasherDefault<FxHasher>>;

/// Hash a tuple of interned constants.
#[inline]
pub fn hash_tuple(t: &[u32]) -> u64 {
    let mut h: u64 = 0;
    for &x in t {
        h = (h.rotate_left(5) ^ u64::from(x)).wrapping_mul(K);
    }
    h = (h ^ (h >> 32)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    h ^ (h >> 32)
}
