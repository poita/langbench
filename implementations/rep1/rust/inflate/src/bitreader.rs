//! LSB-first bit reader over a byte slice.

use crate::error::{Error, Result};

/// Reads bits from a byte slice, least-significant bit of each byte first.
///
/// Peeking past the end of the input yields zero bits, but *consuming* bits
/// that do not exist is an [`Error::UnexpectedEof`].
pub struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
    buf: u64,
    count: u32,
}

impl<'a> BitReader<'a> {
    /// Creates a reader positioned at the first bit of `data`.
    pub fn new(data: &'a [u8]) -> Self {
        BitReader { data, pos: 0, buf: 0, count: 0 }
    }

    #[inline]
    fn refill(&mut self) {
        while self.count <= 56 && self.pos < self.data.len() {
            self.buf |= (self.data[self.pos] as u64) << self.count;
            self.pos += 1;
            self.count += 8;
        }
    }

    /// Returns the next `n` (at most 32) bits without consuming them.
    /// Bits beyond the end of the input read as zero.
    #[inline]
    pub fn peek(&mut self, n: u32) -> u32 {
        debug_assert!(n <= 32);
        if self.count < n {
            self.refill();
        }
        (self.buf & ((1u64 << n) - 1)) as u32
    }

    /// Consumes `n` bits previously examined with [`peek`](Self::peek).
    #[inline]
    pub fn consume(&mut self, n: u32) -> Result<()> {
        if n > self.count {
            return Err(Error::UnexpectedEof);
        }
        self.buf >>= n;
        self.count -= n;
        Ok(())
    }

    /// Reads an `n`-bit (at most 32) number, first bit read being bit 0.
    #[inline]
    pub fn read_bits(&mut self, n: u32) -> Result<u32> {
        let v = self.peek(n);
        self.consume(n)?;
        Ok(v)
    }

    /// Discards the bits remaining in the current partially-read byte.
    pub fn align_to_byte(&mut self) {
        let drop = self.count % 8;
        self.buf >>= drop;
        self.count -= drop;
    }

    /// Appends `len` bytes to `out`; the reader must be byte-aligned.
    pub fn copy_bytes(&mut self, len: usize, out: &mut Vec<u8>) -> Result<()> {
        debug_assert_eq!(self.count % 8, 0);
        let available = (self.count / 8) as usize + (self.data.len() - self.pos);
        if len > available {
            return Err(Error::UnexpectedEof);
        }
        let mut remaining = len;
        while remaining > 0 && self.count > 0 {
            out.push(self.buf as u8);
            self.buf >>= 8;
            self.count -= 8;
            remaining -= 1;
        }
        out.extend_from_slice(&self.data[self.pos..self.pos + remaining]);
        self.pos += remaining;
        Ok(())
    }

    /// Number of whole bytes not yet consumed (after dropping partial bits).
    pub fn whole_bytes_left(&self) -> usize {
        (self.count / 8) as usize + (self.data.len() - self.pos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_lsb_first() {
        let mut r = BitReader::new(&[0b1010_0101, 0xff]);
        assert_eq!(r.read_bits(1).unwrap(), 1);
        assert_eq!(r.read_bits(3).unwrap(), 0b010);
        assert_eq!(r.read_bits(8).unwrap(), 0b1111_1010);
    }

    #[test]
    fn peek_pads_but_consume_fails() {
        let mut r = BitReader::new(&[0x01]);
        assert_eq!(r.peek(15), 1);
        assert_eq!(r.consume(9), Err(Error::UnexpectedEof));
        assert_eq!(r.read_bits(8).unwrap(), 1);
        assert_eq!(r.read_bits(1), Err(Error::UnexpectedEof));
    }

    #[test]
    fn aligned_copy_uses_buffer_then_slice() {
        let data: Vec<u8> = (0..20).collect();
        let mut r = BitReader::new(&data);
        r.read_bits(3).unwrap();
        r.align_to_byte();
        let mut out = Vec::new();
        r.copy_bytes(10, &mut out).unwrap();
        assert_eq!(out, (1..11).collect::<Vec<u8>>());
        assert_eq!(r.whole_bytes_left(), 9);
        assert_eq!(r.copy_bytes(10, &mut out), Err(Error::UnexpectedEof));
    }
}
