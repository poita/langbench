//! A fixed-size set of bytes, used for character classes and first-byte
//! prefilters.

/// A set of byte values `0..=255`, stored as a 256-bit bitmap.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct CharSet {
    bits: [u64; 4],
}

impl CharSet {
    /// The empty set.
    pub const fn new() -> Self {
        CharSet { bits: [0; 4] }
    }

    /// The set containing every byte.
    pub const fn full() -> Self {
        CharSet { bits: [u64::MAX; 4] }
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
    pub fn union_with(&mut self, other: &CharSet) {
        for (a, b) in self.bits.iter_mut().zip(other.bits.iter()) {
            *a |= *b;
        }
    }

    /// Replaces the set with its complement over `0..=255`.
    pub fn negate(&mut self) {
        for w in self.bits.iter_mut() {
            *w = !*w;
        }
    }

    /// Whether `b` is in the set.
    #[inline]
    pub fn contains(&self, b: u8) -> bool {
        self.bits[(b >> 6) as usize] & (1u64 << (b & 63)) != 0
    }

    /// Whether the set is empty.
    pub fn is_empty(&self) -> bool {
        self.bits.iter().all(|&w| w == 0)
    }

    /// `[0-9]`
    pub fn digit() -> Self {
        let mut s = CharSet::new();
        s.insert_range(b'0', b'9');
        s
    }

    /// `[A-Za-z0-9_]`
    pub fn word() -> Self {
        let mut s = CharSet::new();
        s.insert_range(b'0', b'9');
        s.insert_range(b'A', b'Z');
        s.insert_range(b'a', b'z');
        s.insert(b'_');
        s
    }

    /// Space, tab, newline, carriage return, form feed, vertical tab.
    pub fn space() -> Self {
        let mut s = CharSet::new();
        for &b in b" \t\n\r\x0c\x0b" {
            s.insert(b);
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_contains() {
        let mut s = CharSet::new();
        assert!(s.is_empty());
        s.insert(b'a');
        s.insert(255);
        s.insert(0);
        assert!(s.contains(b'a') && s.contains(255) && s.contains(0));
        assert!(!s.contains(b'b'));
    }

    #[test]
    fn ranges_and_negation() {
        let mut s = CharSet::new();
        s.insert_range(b'a', b'c');
        assert!(s.contains(b'b') && !s.contains(b'd'));
        s.negate();
        assert!(!s.contains(b'b') && s.contains(b'd'));
    }

    #[test]
    fn classes() {
        assert!(CharSet::digit().contains(b'7') && !CharSet::digit().contains(b'a'));
        assert!(CharSet::word().contains(b'_') && !CharSet::word().contains(b'-'));
        assert!(CharSet::space().contains(b' ') && CharSet::space().contains(b'\t'));
    }

    #[test]
    fn union() {
        let mut a = CharSet::digit();
        a.union_with(&CharSet::space());
        assert!(a.contains(b'0') && a.contains(b' ') && !a.contains(b'x'));
    }
}
