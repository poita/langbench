//! Table-driven canonical Huffman decoding.
//!
//! A [`Huffman`] holds a two-level lookup table. The root table is indexed by
//! the next `root_bits` stream bits (LSB-first, i.e. the code reversed).
//! Codes longer than the root width go through a second-level table reached
//! from a link entry. Every symbol therefore costs one or two lookups, and
//! building a table costs O(symbols + 2^root_bits + size of subtables).

use crate::bitreader::BitReader;
use crate::error::{Error, Result};
use crate::tables::MAX_CODE_LEN;

const KIND_INVALID: u8 = 0;
const KIND_SYMBOL: u8 = 1;
const KIND_LINK: u8 = 2;

#[derive(Clone, Copy)]
struct Entry {
    /// Symbol for `KIND_SYMBOL`, offset of the subtable for `KIND_LINK`.
    value: u16,
    /// Code length for `KIND_SYMBOL`, subtable index width for `KIND_LINK`.
    bits: u8,
    kind: u8,
}

const INVALID: Entry = Entry { value: 0, bits: 0, kind: KIND_INVALID };

/// A canonical Huffman code compiled into lookup tables.
pub struct Huffman {
    table: Vec<Entry>,
    root_bits: u32,
    num_codes: usize,
    complete: bool,
}

#[inline]
fn reverse_bits(code: u32, len: u32) -> u32 {
    code.reverse_bits() >> (32 - len)
}

impl Huffman {
    /// Builds a decoder from per-symbol code lengths (0 = unused, at most 15).
    ///
    /// Over-subscribed sets are rejected. Incomplete sets are accepted; the
    /// unassigned bit patterns decode to [`Error::InvalidCode`], and
    /// [`is_complete`](Self::is_complete) lets the caller apply its own policy.
    pub fn from_lengths(lengths: &[u8], root_bits: u32) -> Result<Huffman> {
        let mut count = [0u32; MAX_CODE_LEN + 1];
        for &l in lengths {
            debug_assert!((l as usize) <= MAX_CODE_LEN);
            count[l as usize] += 1;
        }
        count[0] = 0;

        // Kraft sum scaled by 2^15.
        let kraft: u32 = (1..=MAX_CODE_LEN).map(|l| count[l] << (MAX_CODE_LEN - l)).sum();
        if kraft > 1 << MAX_CODE_LEN {
            return Err(Error::OverSubscribedCode);
        }
        let num_codes: usize = count.iter().sum::<u32>() as usize;

        let mut next_code = [0u32; MAX_CODE_LEN + 2];
        let mut code = 0u32;
        for l in 1..=MAX_CODE_LEN {
            code = (code + count[l - 1]) << 1;
            next_code[l] = code;
        }

        // Assign codes (reversed for LSB-first lookup).
        let mut codes: Vec<(u32, u8, u16)> = Vec::with_capacity(num_codes);
        for (sym, &l) in lengths.iter().enumerate() {
            if l != 0 {
                let c = next_code[l as usize];
                next_code[l as usize] += 1;
                codes.push((reverse_bits(c, l as u32), l, sym as u16));
            }
        }

        let root_size = 1usize << root_bits;
        let root_mask = (root_size - 1) as u32;
        let mut table = vec![INVALID; root_size];

        // Pass 1: widest code under each root prefix that needs a subtable.
        let mut sub_max = vec![0u8; root_size];
        for &(rev, l, _) in &codes {
            if l as u32 > root_bits {
                let p = (rev & root_mask) as usize;
                sub_max[p] = sub_max[p].max(l);
            }
        }
        for p in 0..root_size {
            if sub_max[p] != 0 {
                let bits = sub_max[p] as u32 - root_bits;
                table[p] = Entry { value: table.len() as u16, bits: bits as u8, kind: KIND_LINK };
                let new_len = table.len() + (1usize << bits);
                table.resize(new_len, INVALID);
            }
        }

        // Pass 2: fill in symbols.
        for &(rev, l, sym) in &codes {
            let l = l as u32;
            let entry = Entry { value: sym, bits: l as u8, kind: KIND_SYMBOL };
            if l <= root_bits {
                let mut i = rev as usize;
                while i < root_size {
                    table[i] = entry;
                    i += 1 << l;
                }
            } else {
                let link = table[(rev & root_mask) as usize];
                let base = link.value as usize;
                let size = 1usize << link.bits;
                let step = 1usize << (l - root_bits);
                let mut i = (rev >> root_bits) as usize;
                while i < size {
                    table[base + i] = entry;
                    i += step;
                }
            }
        }

        Ok(Huffman { table, root_bits, num_codes, complete: kraft == 1 << MAX_CODE_LEN })
    }

    /// True if the code lengths satisfied the Kraft equality exactly.
    pub fn is_complete(&self) -> bool {
        self.complete
    }

    /// Number of symbols that have a code.
    pub fn num_codes(&self) -> usize {
        self.num_codes
    }

    /// Decodes one symbol, consuming exactly its code's bits.
    #[inline]
    pub fn decode(&self, br: &mut BitReader) -> Result<u16> {
        let bits = br.peek(MAX_CODE_LEN as u32);
        let mut e = self.table[(bits & ((1 << self.root_bits) - 1)) as usize];
        if e.kind == KIND_LINK {
            let idx = (bits >> self.root_bits) & ((1u32 << e.bits) - 1);
            e = self.table[e.value as usize + idx as usize];
        }
        if e.kind != KIND_SYMBOL {
            return Err(Error::InvalidCode);
        }
        br.consume(e.bits as u32)?;
        Ok(e.value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_rfc_example() {
        // RFC 1951 3.2.2: lengths (3,3,3,3,3,2,4,4) -> A=010 .. F=00, G=1110, H=1111.
        let h = Huffman::from_lengths(&[3, 3, 3, 3, 3, 2, 4, 4], 3).unwrap();
        assert!(h.is_complete());
        // Codes MSB-first: F=00, A=010, G=1110; pack bits in reading order.
        // bits read: 0,0 | 0,1,0 | 1,1,1,0  -> byte LSB first: 0b0_1110_1_0_00 ...
        let bits = [0, 0, 0, 1, 0, 1, 1, 1, 0];
        let mut bytes = vec![0u8; 2];
        for (i, b) in bits.iter().enumerate() {
            bytes[i / 8] |= b << (i % 8);
        }
        let mut br = BitReader::new(&bytes);
        assert_eq!(h.decode(&mut br).unwrap(), 5);
        assert_eq!(h.decode(&mut br).unwrap(), 0);
        assert_eq!(h.decode(&mut br).unwrap(), 6);
    }

    #[test]
    fn rejects_over_subscribed() {
        assert_eq!(Huffman::from_lengths(&[1, 1, 1], 7).err(), Some(Error::OverSubscribedCode));
    }

    #[test]
    fn incomplete_single_code() {
        let h = Huffman::from_lengths(&[1], 7).unwrap();
        assert!(!h.is_complete());
        let mut br = BitReader::new(&[0b10]);
        assert_eq!(h.decode(&mut br).unwrap(), 0);
        assert_eq!(h.decode(&mut br), Err(Error::InvalidCode));
    }

    #[test]
    fn long_codes_use_subtables() {
        // Lengths 1,2,...,14,15,15 form a complete code with 15-bit codes.
        let mut lengths: Vec<u8> = (1..=15).collect();
        lengths.push(15);
        let h = Huffman::from_lengths(&lengths, 4).unwrap();
        assert!(h.is_complete());
        // Last symbol (index 15) has code 111111111111111; bytes of all ones.
        let mut br = BitReader::new(&[0xff, 0xff]);
        assert_eq!(h.decode(&mut br).unwrap(), 15);
        // Symbol 14 (length 15) has code 111111111111110.
        let mut br = BitReader::new(&[0xff, 0x3f]);
        assert_eq!(h.decode(&mut br).unwrap(), 14);
        // Symbol 9 (length 10): code 1111111110.
        let mut br = BitReader::new(&[0xff, 0x01]);
        assert_eq!(h.decode(&mut br).unwrap(), 9);
    }
}
