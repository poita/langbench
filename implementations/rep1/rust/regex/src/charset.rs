//! A set of byte values, used for character classes and first-byte filters.

/// A set of bytes (`0..=255`) stored as a 256-bit bitmap.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct ByteSet {
    bits: [u64; 4],
}

impl ByteSet {
    /// The empty set.
    pub const fn new() -> Self {
        ByteSet { bits: [0; 4] }
    }

    /// The set containing every byte.
    pub const fn full() -> Self {
        ByteSet { bits: [u64::MAX; 4] }
    }

    /// Adds one byte.
    pub fn insert(&mut self, b: u8) {
        self.bits[(b >> 6) as usize] |= 1u64 << (b & 63);
    }

    /// Adds every byte in `lo..=hi`.
    pub fn insert_range(&mut self, lo: u8, hi: u8) {
        for b in lo..=hi {
            self.insert(b);
        }
    }

    /// Adds every byte of `other`.
    pub fn union_with(&mut self, other: &ByteSet) {
        for (a, b) in self.bits.iter_mut().zip(other.bits.iter()) {
            *a |= *b;
        }
    }

    /// Replaces the set with its complement over all 256 byte values.
    pub fn negate(&mut self) {
        for w in self.bits.iter_mut() {
            *w = !*w;
        }
    }

    /// Returns true if `b` is in the set.
    #[inline(always)]
    pub fn contains(&self, b: u8) -> bool {
        self.bits[(b >> 6) as usize] >> (b & 63) & 1 != 0
    }

    /// The set `[0-9]`.
    pub fn digits() -> Self {
        let mut s = Self::new();
        s.insert_range(b'0', b'9');
        s
    }

    /// The set `[A-Za-z0-9_]`.
    pub fn word() -> Self {
        let mut s = Self::new();
        s.insert_range(b'0', b'9');
        s.insert_range(b'a', b'z');
        s.insert_range(b'A', b'Z');
        s.insert(b'_');
        s
    }

    /// The set of whitespace characters: space, `\t`, `\n`, `\r`, `\f`, `\v`.
    pub fn space() -> Self {
        let mut s = Self::new();
        for b in [b' ', b'\t', b'\n', b'\r', 0x0c, 0x0b] {
            s.insert(b);
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_contains_negate() {
        let mut s = ByteSet::new();
        s.insert(b'a');
        s.insert_range(b'0', b'3');
        assert!(s.contains(b'a') && s.contains(b'2') && !s.contains(b'b'));
        s.negate();
        assert!(!s.contains(b'a') && s.contains(b'b') && s.contains(200));
    }

    #[test]
    fn predefined() {
        assert!(ByteSet::digits().contains(b'7'));
        assert!(ByteSet::word().contains(b'_') && !ByteSet::word().contains(b'-'));
        assert!(ByteSet::space().contains(b' ') && !ByteSet::space().contains(b'x'));
    }
}
