//! A from-scratch decoder for DEFLATE (RFC 1951) and the zlib wrapper
//! (RFC 1950).
//!
//! The decoder is self-terminating: it reports how many input bytes the
//! stream occupied, so several streams can sit back to back in one buffer.
//! The Adler-32 trailer of a zlib stream is not verified; objects are
//! validated by their SHA-1 instead.

use crate::error::{Error, Result};

/// The result of decoding one stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Inflated {
    /// The decompressed bytes.
    pub data: Vec<u8>,
    /// How many input bytes were used. For [`zlib_decompress`] this covers
    /// the two header bytes and the DEFLATE stream but not the four-byte
    /// Adler-32 trailer.
    pub consumed: usize,
}

const MAX_BITS: usize = 15;

/// Decompresses a zlib stream (two header bytes, DEFLATE data, trailer).
///
/// Fails when the header is not a plain deflate header, when the data is not
/// valid DEFLATE or when it is truncated.
pub fn zlib_decompress(input: &[u8]) -> Result<Inflated> {
    if input.len() < 2 {
        return Err(Error::corrupt("zlib stream too short"));
    }
    let (cmf, flg) = (input[0] as u32, input[1] as u32);
    if cmf & 0x0f != 8 || (cmf * 256 + flg) % 31 != 0 || flg & 0x20 != 0 {
        return Err(Error::corrupt("bad zlib header"));
    }
    let mut inner = inflate(&input[2..])?;
    inner.consumed += 2;
    Ok(inner)
}

/// Decompresses a raw DEFLATE stream.
pub fn inflate(input: &[u8]) -> Result<Inflated> {
    let mut bits = BitReader { data: input, pos: 0, buf: 0, count: 0 };
    let mut out = Vec::new();
    loop {
        let last = bits.bits(1)?;
        match bits.bits(2)? {
            0 => stored_block(&mut bits, &mut out)?,
            1 => {
                let (lit, dist) = fixed_tables();
                compressed_block(&mut bits, &mut out, &lit, &dist)?;
            }
            2 => {
                let (lit, dist) = dynamic_tables(&mut bits)?;
                compressed_block(&mut bits, &mut out, &lit, &dist)?;
            }
            _ => return Err(Error::corrupt("reserved deflate block type")),
        }
        if last == 1 {
            break;
        }
    }
    Ok(Inflated { data: out, consumed: bits.pos })
}

struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
    buf: u32,
    count: u32,
}

impl BitReader<'_> {
    /// Reads `n <= 16` bits, least significant first.
    fn bits(&mut self, n: u32) -> Result<u32> {
        while self.count < n {
            let byte = *self
                .data
                .get(self.pos)
                .ok_or_else(|| Error::corrupt("unexpected end of deflate stream"))?;
            self.pos += 1;
            self.buf |= (byte as u32) << self.count;
            self.count += 8;
        }
        let v = self.buf & ((1u32 << n) - 1);
        self.buf >>= n;
        self.count -= n;
        Ok(v)
    }
}

/// A canonical Huffman code in the "counts per length" form.
struct Huffman {
    count: [u16; MAX_BITS + 1],
    symbol: Vec<u16>,
}

impl Huffman {
    /// Builds a code from per-symbol lengths. Returns the code and whether
    /// it is *complete* (every bit pattern decodes). Over-subscribed codes
    /// are rejected.
    fn new(lengths: &[u8]) -> Result<(Huffman, bool)> {
        let mut count = [0u16; MAX_BITS + 1];
        for &l in lengths {
            count[l as usize] += 1;
        }
        let mut left: i32 = 1;
        for &c in &count[1..] {
            left <<= 1;
            left -= c as i32;
            if left < 0 {
                return Err(Error::corrupt("over-subscribed Huffman code"));
            }
        }
        let mut offs = [0u16; MAX_BITS + 2];
        for len in 1..=MAX_BITS {
            offs[len + 1] = offs[len] + count[len];
        }
        let mut symbol = vec![0u16; lengths.len()];
        for (sym, &l) in lengths.iter().enumerate() {
            if l != 0 {
                symbol[offs[l as usize] as usize] = sym as u16;
                offs[l as usize] += 1;
            }
        }
        Ok((Huffman { count, symbol }, left == 0))
    }

    fn decode(&self, bits: &mut BitReader) -> Result<u16> {
        let (mut code, mut first, mut index) = (0i32, 0i32, 0i32);
        for len in 1..=MAX_BITS {
            code |= bits.bits(1)? as i32;
            let count = self.count[len] as i32;
            if code - count < first {
                return Ok(self.symbol[(index + (code - first)) as usize]);
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        Err(Error::corrupt("invalid Huffman code"))
    }
}

fn stored_block(bits: &mut BitReader, out: &mut Vec<u8>) -> Result<()> {
    // Discard the rest of the current byte; whole bytes were loaded only
    // when needed, so no complete unread byte is buffered.
    bits.buf = 0;
    bits.count = 0;
    let header = bits
        .data
        .get(bits.pos..bits.pos + 4)
        .ok_or_else(|| Error::corrupt("truncated stored block"))?;
    let len = u16::from_le_bytes([header[0], header[1]]);
    let nlen = u16::from_le_bytes([header[2], header[3]]);
    if len != !nlen {
        return Err(Error::corrupt("stored block length mismatch"));
    }
    let start = bits.pos + 4;
    let body = bits
        .data
        .get(start..start + len as usize)
        .ok_or_else(|| Error::corrupt("truncated stored block"))?;
    out.extend_from_slice(body);
    bits.pos = start + len as usize;
    Ok(())
}

fn fixed_tables() -> (Huffman, Huffman) {
    let mut lengths = [0u8; 288];
    for (i, l) in lengths.iter_mut().enumerate() {
        *l = match i {
            0..=143 => 8,
            144..=255 => 9,
            256..=279 => 7,
            _ => 8,
        };
    }
    let lit = Huffman::new(&lengths).expect("fixed literal code is valid").0;
    let dist = Huffman::new(&[5u8; 30]).expect("fixed distance code is valid").0;
    (lit, dist)
}

fn dynamic_tables(bits: &mut BitReader) -> Result<(Huffman, Huffman)> {
    const ORDER: [usize; 19] =
        [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    let nlen = bits.bits(5)? as usize + 257;
    let ndist = bits.bits(5)? as usize + 1;
    let ncode = bits.bits(4)? as usize + 4;
    if nlen > 286 || ndist > 30 {
        return Err(Error::corrupt("too many length or distance codes"));
    }
    let mut cl = [0u8; 19];
    for &slot in ORDER.iter().take(ncode) {
        cl[slot] = bits.bits(3)? as u8;
    }
    let (code_len, complete) = Huffman::new(&cl)?;
    if !complete {
        return Err(Error::corrupt("incomplete code-length code"));
    }
    let mut lengths = [0u8; 286 + 30];
    let mut i = 0;
    while i < nlen + ndist {
        let sym = code_len.decode(bits)?;
        if sym < 16 {
            lengths[i] = sym as u8;
            i += 1;
            continue;
        }
        let (value, repeat) = match sym {
            16 => {
                if i == 0 {
                    return Err(Error::corrupt("repeat with no previous length"));
                }
                (lengths[i - 1], 3 + bits.bits(2)? as usize)
            }
            17 => (0, 3 + bits.bits(3)? as usize),
            _ => (0, 11 + bits.bits(7)? as usize),
        };
        if i + repeat > nlen + ndist {
            return Err(Error::corrupt("too many code lengths"));
        }
        for l in &mut lengths[i..i + repeat] {
            *l = value;
        }
        i += repeat;
    }
    if lengths[256] == 0 {
        return Err(Error::corrupt("no end-of-block code"));
    }
    let (lit, lit_complete) = Huffman::new(&lengths[..nlen])?;
    if !lit_complete && nlen != lit.count[0] as usize + lit.count[1] as usize {
        return Err(Error::corrupt("incomplete literal/length code"));
    }
    let (dist, dist_complete) = Huffman::new(&lengths[nlen..nlen + ndist])?;
    if !dist_complete && ndist != dist.count[0] as usize + dist.count[1] as usize {
        return Err(Error::corrupt("incomplete distance code"));
    }
    Ok((lit, dist))
}

const LEN_BASE: [u16; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
    131, 163, 195, 227, 258,
];
const LEN_EXTRA: [u8; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: [u16; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [u8; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];

fn compressed_block(
    bits: &mut BitReader,
    out: &mut Vec<u8>,
    lit: &Huffman,
    dist: &Huffman,
) -> Result<()> {
    loop {
        let sym = lit.decode(bits)? as usize;
        if sym < 256 {
            out.push(sym as u8);
        } else if sym == 256 {
            return Ok(());
        } else {
            let sym = sym - 257;
            if sym >= 29 {
                return Err(Error::corrupt("invalid length symbol"));
            }
            let len = LEN_BASE[sym] as usize + bits.bits(LEN_EXTRA[sym] as u32)? as usize;
            let dsym = dist.decode(bits)? as usize;
            if dsym >= 30 {
                return Err(Error::corrupt("invalid distance symbol"));
            }
            let d = DIST_BASE[dsym] as usize + bits.bits(DIST_EXTRA[dsym] as u32)? as usize;
            if d > out.len() {
                return Err(Error::corrupt("distance too far back"));
            }
            let start = out.len() - d;
            if d >= len {
                out.extend_from_within(start..start + len);
            } else {
                for k in 0..len {
                    out.push(out[start + k]);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_huffman_hello() {
        let z = [0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15];
        let r = zlib_decompress(&z).unwrap();
        assert_eq!(r.data, b"hello");
        assert_eq!(r.consumed, 9);
    }

    #[test]
    fn stored_block_and_trailing_bytes() {
        let mut z = vec![0x78, 0x01, 0x01, 3, 0, 0xfc, 0xff, b'a', b'b', b'c'];
        z.extend_from_slice(&[0, 0, 0, 0]); // adler (ignored)
        z.extend_from_slice(b"next");
        let r = zlib_decompress(&z).unwrap();
        assert_eq!(r.data, b"abc");
        assert_eq!(r.consumed, 10);
    }

    #[test]
    fn overlapping_copy() {
        // Fixed block: literal 'a', then length 5 distance 1 => "aaaaaa".
        // Bits: BFINAL=1, BTYPE=01, 'a'(0x61+0x30=0x91, 8 bits), len 5 =
        // symbol 259 (7 bits 0000011), dist code 0 (5 bits), EOB (7 zeros).
        let z = [0x4b, 0x4c, 0x04, 0x01, 0x00];
        assert_eq!(inflate(&z).unwrap().data, b"aaaaaa");
    }

    #[test]
    fn rejects_bad_headers() {
        assert!(zlib_decompress(&[0x78]).is_err());
        assert!(zlib_decompress(&[0x79, 0x9c, 0x03, 0x00]).is_err());
        assert!(zlib_decompress(&[0x78, 0x9d, 0x03, 0x00]).is_err());
        // FDICT set (0x7820 + check bits)
        assert!(zlib_decompress(&[0x78, 0xbb, 0x03, 0x00]).is_err());
    }

    #[test]
    fn rejects_truncated_and_reserved() {
        assert!(inflate(&[0x07]).is_err()); // reserved block type 3
        assert!(inflate(&[0xcb, 0x48]).is_err()); // truncated
        assert!(inflate(&[0x01, 3, 0, 0xfc]).is_err()); // truncated stored
        assert!(inflate(&[0x01, 3, 0, 0xfd, 0xff, 1, 2, 3]).is_err()); // bad nlen
    }
}
