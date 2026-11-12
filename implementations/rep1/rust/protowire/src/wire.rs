//! Low-level wire-format primitives: varints, zigzag, tags and a bounds-checked
//! byte reader.

use crate::error::{Error, Result};

/// Longest varint accepted on decode.
pub const MAX_VARINT_LEN: usize = 10;
/// Longest tag accepted on decode.
pub const MAX_TAG_LEN: usize = 5;
/// Longest length prefix accepted on decode.
pub const MAX_LEN_PREFIX_LEN: usize = 5;

/// The wire types of the protobuf format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireType {
    /// Wire type 0: one varint.
    Varint = 0,
    /// Wire type 1: 8 bytes.
    Fixed64 = 1,
    /// Wire type 2: length-prefixed bytes.
    Len = 2,
    /// Wire type 3: start of a group.
    StartGroup = 3,
    /// Wire type 4: end of a group.
    EndGroup = 4,
    /// Wire type 5: 4 bytes.
    Fixed32 = 5,
}

impl WireType {
    fn from_bits(bits: u64) -> Option<WireType> {
        Some(match bits {
            0 => WireType::Varint,
            1 => WireType::Fixed64,
            2 => WireType::Len,
            3 => WireType::StartGroup,
            4 => WireType::EndGroup,
            5 => WireType::Fixed32,
            _ => return None,
        })
    }
}

/// A decoded field tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tag {
    /// Field number, at least 1.
    pub number: u32,
    /// Wire type.
    pub wire: WireType,
}

/// Number of bytes in the minimal varint encoding of `v`.
#[inline]
pub fn varint_len(v: u64) -> usize {
    let bits = 64 - (v | 1).leading_zeros() as usize;
    bits.div_ceil(7)
}

/// Appends the minimal varint encoding of `v`.
#[inline]
pub fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

/// Appends the tag for `number` and `wire`.
#[inline]
pub fn put_tag(out: &mut Vec<u8>, number: u32, wire: WireType) {
    put_varint(out, tag_value(number, wire));
}

/// The numeric value of a tag.
#[inline]
pub fn tag_value(number: u32, wire: WireType) -> u64 {
    ((number as u64) << 3) | wire as u64
}

/// Zigzag-encodes a 32-bit signed integer.
#[inline]
pub fn zigzag32(v: i32) -> u32 {
    ((v << 1) ^ (v >> 31)) as u32
}

/// Zigzag-encodes a 64-bit signed integer.
#[inline]
pub fn zigzag64(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

/// Inverse of [`zigzag32`].
#[inline]
pub fn unzigzag32(u: u32) -> i32 {
    ((u >> 1) as i32) ^ -((u & 1) as i32)
}

/// Inverse of [`zigzag64`].
#[inline]
pub fn unzigzag64(u: u64) -> i64 {
    ((u >> 1) as i64) ^ -((u & 1) as i64)
}

/// A cursor over a byte slice. Every read is bounds-checked and advances
/// the cursor exactly once over each byte.
#[derive(Debug, Clone)]
pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    /// Creates a reader over `buf`.
    pub fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    /// True when every byte has been consumed.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.pos >= self.buf.len()
    }

    /// Number of unread bytes.
    #[inline]
    pub fn remaining(&self) -> usize {
        self.buf.len() - self.pos
    }

    /// Reads a varint of at most `max_len` bytes. Bits beyond bit 63 are
    /// discarded.
    #[inline]
    pub fn read_varint_max(&mut self, max_len: usize) -> Result<u64> {
        let mut result = 0u64;
        for i in 0..max_len {
            let Some(&b) = self.buf.get(self.pos) else {
                return Err(Error::Wire("truncated varint"));
            };
            self.pos += 1;
            result |= ((b & 0x7f) as u64) << (7 * i);
            if b & 0x80 == 0 {
                return Ok(result);
            }
        }
        Err(Error::Wire("varint too long"))
    }

    /// Reads a value varint (at most 10 bytes).
    #[inline]
    pub fn read_varint(&mut self) -> Result<u64> {
        self.read_varint_max(MAX_VARINT_LEN)
    }

    /// Reads and validates a field tag.
    #[inline]
    pub fn read_tag(&mut self) -> Result<Tag> {
        let v = self.read_varint_max(MAX_TAG_LEN)?;
        if v >> 32 != 0 {
            return Err(Error::Wire("tag exceeds 32 bits"));
        }
        let number = (v >> 3) as u32;
        if number == 0 {
            return Err(Error::Wire("field number 0"));
        }
        let wire = WireType::from_bits(v & 7).ok_or(Error::Wire("invalid wire type"))?;
        Ok(Tag { number, wire })
    }

    /// Reads `n` raw bytes.
    #[inline]
    pub fn read_bytes(&mut self, n: usize) -> Result<&'a [u8]> {
        if n > self.remaining() {
            return Err(Error::Wire("truncated data"));
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    /// Reads a length prefix and the payload it announces.
    #[inline]
    pub fn read_len_delimited(&mut self) -> Result<&'a [u8]> {
        let len = self.read_varint_max(MAX_LEN_PREFIX_LEN)?;
        if len > self.remaining() as u64 {
            return Err(Error::Wire("length exceeds remaining bytes"));
        }
        self.read_bytes(len as usize)
    }

    /// Reads a little-endian 32-bit value.
    #[inline]
    pub fn read_fixed32(&mut self) -> Result<u32> {
        let b = self.read_bytes(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    /// Reads a little-endian 64-bit value.
    #[inline]
    pub fn read_fixed64(&mut self) -> Result<u64> {
        let b = self.read_bytes(8)?;
        Ok(u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
    }

    /// Skips the payload of a field whose tag has just been read. Groups are
    /// skipped iteratively, so nesting depth costs no stack.
    pub fn skip_field(&mut self, tag: Tag) -> Result<()> {
        match tag.wire {
            WireType::Varint => {
                self.read_varint()?;
            }
            WireType::Fixed64 => {
                self.read_bytes(8)?;
            }
            WireType::Fixed32 => {
                self.read_bytes(4)?;
            }
            WireType::Len => {
                self.read_len_delimited()?;
            }
            WireType::StartGroup => self.skip_group(tag.number)?,
            WireType::EndGroup => return Err(Error::Wire("unexpected end group")),
        }
        Ok(())
    }

    fn skip_group(&mut self, number: u32) -> Result<()> {
        let mut open = vec![number];
        while let Some(&top) = open.last() {
            let tag = self.read_tag()?;
            match tag.wire {
                WireType::EndGroup => {
                    if tag.number != top {
                        return Err(Error::Wire("mismatched end group"));
                    }
                    open.pop();
                }
                WireType::StartGroup => open.push(tag.number),
                _ => self.skip_field(tag)?,
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn varint(bytes: &[u8]) -> Result<u64> {
        Reader::new(bytes).read_varint()
    }

    #[test]
    fn varint_lengths() {
        assert_eq!(varint_len(0), 1);
        assert_eq!(varint_len(127), 1);
        assert_eq!(varint_len(128), 2);
        assert_eq!(varint_len(300), 2);
        assert_eq!(varint_len(u64::MAX), 10);
    }

    #[test]
    fn put_and_read_varint() {
        for v in [0u64, 1, 127, 128, 300, 1 << 35, u64::MAX] {
            let mut out = Vec::new();
            put_varint(&mut out, v);
            assert_eq!(out.len(), varint_len(v));
            assert_eq!(varint(&out).unwrap(), v);
        }
        let mut out = Vec::new();
        put_varint(&mut out, 300);
        assert_eq!(out, [0xac, 0x02]);
    }

    #[test]
    fn varint_edges() {
        assert_eq!(varint(&[0x81, 0x00]).unwrap(), 1);
        assert_eq!(varint(&[0xff; 9].iter().copied().chain([0x7f]).collect::<Vec<_>>()).unwrap(), u64::MAX);
        let mut b = vec![0x80; 9];
        b.push(0x02);
        assert_eq!(varint(&b).unwrap(), 0);
        assert!(varint(&[0x80; 10]).is_err());
        assert!(varint(&[0xff]).is_err());
        assert!(varint(&[]).is_err());
    }

    #[test]
    fn tags() {
        let t = Reader::new(&[0x08]).read_tag().unwrap();
        assert_eq!((t.number, t.wire), (1, WireType::Varint));
        assert!(Reader::new(&[0x00]).read_tag().is_err());
        assert!(Reader::new(&[0x0e]).read_tag().is_err()); // wire type 6
        assert!(Reader::new(&[0x80, 0x80, 0x80, 0x80, 0x80, 0x00]).read_tag().is_err());
        // tag of exactly 2^32 does not fit
        assert!(Reader::new(&[0x80, 0x80, 0x80, 0x80, 0x10]).read_tag().is_err());
    }

    #[test]
    fn zigzag() {
        assert_eq!(zigzag32(-1), 1);
        assert_eq!(zigzag32(i32::MIN), u32::MAX);
        assert_eq!(zigzag64(i64::MIN), u64::MAX);
        assert_eq!(unzigzag32(zigzag32(-12345)), -12345);
        assert_eq!(unzigzag64(zigzag64(i64::MAX)), i64::MAX);
    }

    #[test]
    fn length_prefix() {
        assert_eq!(Reader::new(&[2, 1, 2]).read_len_delimited().unwrap(), &[1, 2]);
        assert!(Reader::new(&[3, 1, 2]).read_len_delimited().is_err());
        assert!(Reader::new(&[0x80, 0x80, 0x80, 0x80, 0x80, 0x00]).read_len_delimited().is_err());
    }

    #[test]
    fn groups() {
        // start group 1, varint field 1, nested group 2, end 2, end 1
        let data = [0x0b, 0x08, 0x01, 0x13, 0x14, 0x0c];
        let mut r = Reader::new(&data);
        let tag = r.read_tag().unwrap();
        r.skip_field(tag).unwrap();
        assert!(r.is_empty());
        // mismatched end
        let data = [0x0b, 0x14];
        let mut r = Reader::new(&data);
        let tag = r.read_tag().unwrap();
        assert!(r.skip_field(tag).is_err());
        // unterminated
        let data = [0x0b, 0x08, 0x01];
        let mut r = Reader::new(&data);
        let tag = r.read_tag().unwrap();
        assert!(r.skip_field(tag).is_err());
    }
}
