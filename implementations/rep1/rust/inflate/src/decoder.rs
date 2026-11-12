//! The DEFLATE block decoder.

use crate::bitreader::BitReader;
use crate::error::{Error, Result};
use crate::huffman::Huffman;
use crate::tables::*;

const LITLEN_ROOT_BITS: u32 = 10;
const DIST_ROOT_BITS: u32 = 8;
const CODELEN_ROOT_BITS: u32 = 7;

/// Decompresses a raw DEFLATE stream (RFC 1951) into a new `Vec`.
///
/// The stream must end exactly at the end of its final block, apart from the
/// unused bits of the last byte; any whole byte after it is
/// [`Error::TrailingData`].
///
/// ```
/// let out = inflate::inflate(&[0x01, 0x01, 0x00, 0xfe, 0xff, 0x41]).unwrap();
/// assert_eq!(out, b"A");
/// ```
pub fn inflate(data: &[u8]) -> Result<Vec<u8>> {
    let mut br = BitReader::new(data);
    let mut out = Vec::new();
    loop {
        let is_final = br.read_bits(1)? == 1;
        match br.read_bits(2)? {
            0 => stored_block(&mut br, &mut out)?,
            1 => {
                let lit = Huffman::from_lengths(&fixed_litlen_lengths(), LITLEN_ROOT_BITS)?;
                let dist = Huffman::from_lengths(&fixed_dist_lengths(), DIST_ROOT_BITS)?;
                compressed_block(&mut br, &mut out, &lit, &dist)?;
            }
            2 => {
                let (lit, dist) = read_dynamic_codes(&mut br)?;
                compressed_block(&mut br, &mut out, &lit, &dist)?;
            }
            _ => return Err(Error::InvalidBlockType),
        }
        if is_final {
            break;
        }
    }
    br.align_to_byte();
    if br.whole_bytes_left() != 0 {
        return Err(Error::TrailingData);
    }
    Ok(out)
}

fn stored_block(br: &mut BitReader, out: &mut Vec<u8>) -> Result<()> {
    br.align_to_byte();
    let len = br.read_bits(16)?;
    let nlen = br.read_bits(16)?;
    if len ^ nlen != 0xffff {
        return Err(Error::StoredLengthMismatch);
    }
    br.copy_bytes(len as usize, out)
}

fn read_dynamic_codes(br: &mut BitReader) -> Result<(Huffman, Huffman)> {
    let hlit = br.read_bits(5)? as usize;
    let hdist = br.read_bits(5)? as usize;
    let hclen = br.read_bits(4)? as usize;
    if hlit > 29 || hdist > 29 {
        return Err(Error::TooManyCodes);
    }
    let n_lit = hlit + 257;
    let n_dist = hdist + 1;

    let mut cl_lengths = [0u8; 19];
    for &sym in CODE_LENGTH_ORDER.iter().take(hclen + 4) {
        cl_lengths[sym] = br.read_bits(3)? as u8;
    }
    let cl = Huffman::from_lengths(&cl_lengths, CODELEN_ROOT_BITS)?;
    if !cl.is_complete() {
        return Err(Error::IncompleteCode);
    }

    let total = n_lit + n_dist;
    let mut lengths = [0u8; 286 + 30];
    let mut i = 0;
    while i < total {
        let sym = cl.decode(br)?;
        let (value, repeat) = match sym {
            0..=15 => (sym as u8, 1),
            16 => {
                if i == 0 {
                    return Err(Error::RepeatWithoutPrevious);
                }
                (lengths[i - 1], 3 + br.read_bits(2)? as usize)
            }
            17 => (0, 3 + br.read_bits(3)? as usize),
            _ => (0, 11 + br.read_bits(7)? as usize),
        };
        if i + repeat > total {
            return Err(Error::RepeatOverflow);
        }
        lengths[i..i + repeat].fill(value);
        i += repeat;
    }

    let (lit_lengths, dist_lengths) = lengths[..total].split_at(n_lit);
    if lit_lengths[END_OF_BLOCK as usize] == 0 {
        return Err(Error::MissingEndOfBlock);
    }
    let lit = Huffman::from_lengths(lit_lengths, LITLEN_ROOT_BITS)?;
    if !lit.is_complete() && !is_single_one_bit_code(lit_lengths) {
        return Err(Error::IncompleteCode);
    }
    let dist = Huffman::from_lengths(dist_lengths, DIST_ROOT_BITS)?;
    if !dist.is_complete() && dist.num_codes() != 0 && !is_single_one_bit_code(dist_lengths) {
        return Err(Error::IncompleteCode);
    }
    Ok((lit, dist))
}

fn is_single_one_bit_code(lengths: &[u8]) -> bool {
    lengths.iter().filter(|&&l| l != 0).count() == 1 && lengths.contains(&1)
}

fn compressed_block(
    br: &mut BitReader,
    out: &mut Vec<u8>,
    lit: &Huffman,
    dist: &Huffman,
) -> Result<()> {
    loop {
        let sym = lit.decode(br)? as usize;
        if sym < 256 {
            out.push(sym as u8);
            continue;
        }
        if sym == END_OF_BLOCK as usize {
            return Ok(());
        }
        let idx = sym - 257;
        if idx >= LENGTH_BASE.len() {
            return Err(Error::InvalidSymbol);
        }
        let length = LENGTH_BASE[idx] as usize + br.read_bits(LENGTH_EXTRA[idx] as u32)? as usize;

        if dist.num_codes() == 0 {
            return Err(Error::NoDistanceCodes);
        }
        let dsym = dist.decode(br)? as usize;
        if dsym >= DIST_BASE.len() {
            return Err(Error::InvalidSymbol);
        }
        let distance = DIST_BASE[dsym] as usize + br.read_bits(DIST_EXTRA[dsym] as u32)? as usize;
        if distance > out.len() {
            return Err(Error::DistanceTooFar);
        }
        copy_match(out, distance, length);
    }
}

#[inline]
fn copy_match(out: &mut Vec<u8>, distance: usize, length: usize) {
    let start = out.len() - distance;
    if distance >= length {
        out.extend_from_within(start..start + length);
    } else {
        out.reserve(length);
        for i in 0..length {
            let b = out[start + i];
            out.push(b);
        }
    }
}
