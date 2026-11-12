//! A growable bit string, written most-significant bit first.

/// Append-only sequence of bits.
#[derive(Debug, Default, Clone)]
pub struct BitBuffer {
    bits: Vec<bool>,
}

impl BitBuffer {
    /// Creates an empty buffer.
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of bits stored.
    pub fn len(&self) -> usize {
        self.bits.len()
    }

    /// Whether the buffer holds no bits.
    pub fn is_empty(&self) -> bool {
        self.bits.is_empty()
    }

    /// Appends the low `count` bits of `value`, most significant first.
    pub fn push_bits(&mut self, value: u32, count: usize) {
        debug_assert!(count <= 32);
        for i in (0..count).rev() {
            self.bits.push((value >> i) & 1 != 0);
        }
    }

    /// Packs the bits into bytes, padding the final byte with zeros.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = vec![0u8; self.bits.len().div_ceil(8)];
        for (i, &b) in self.bits.iter().enumerate() {
            if b {
                out[i / 8] |= 0x80 >> (i % 8);
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn msb_first_packing() {
        let mut b = BitBuffer::new();
        b.push_bits(0b101, 3);
        b.push_bits(0b1, 1);
        assert_eq!(b.len(), 4);
        assert_eq!(b.to_bytes(), vec![0b1011_0000]);
    }
}
