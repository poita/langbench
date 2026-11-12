//! Git's delta format: reconstructing an object from a base and a delta.

use crate::error::{Error, Result};

/// Reads a little-endian base-128 size starting at `*pos`.
fn read_size(delta: &[u8], pos: &mut usize) -> Result<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    loop {
        let b = *delta.get(*pos).ok_or_else(|| Error::corrupt("truncated delta header"))?;
        *pos += 1;
        if shift >= 64 {
            return Err(Error::corrupt("delta size too large"));
        }
        value |= ((b & 0x7f) as u64) << shift;
        shift += 7;
        if b & 0x80 == 0 {
            return Ok(value);
        }
    }
}

/// Applies `delta` to `base` and returns the reconstructed bytes.
///
/// Fails if the delta is truncated, uses the invalid `0x00` instruction,
/// declares a base size other than `base.len()`, copies past the end of the
/// base, or produces a result whose length differs from the declared one.
pub fn apply_delta(base: &[u8], delta: &[u8]) -> Result<Vec<u8>> {
    let mut pos = 0;
    let base_size = read_size(delta, &mut pos)?;
    let result_size = read_size(delta, &mut pos)?;
    if base_size != base.len() as u64 {
        return Err(Error::corrupt("delta base size mismatch"));
    }
    let mut out = Vec::with_capacity((result_size as usize).min(1 << 26));
    while pos < delta.len() {
        let op = delta[pos];
        pos += 1;
        if op & 0x80 != 0 {
            let mut offset = 0usize;
            let mut size = 0usize;
            for i in 0..4 {
                if op & (1 << i) != 0 {
                    let b = *delta.get(pos).ok_or_else(|| Error::corrupt("truncated copy"))?;
                    pos += 1;
                    offset |= (b as usize) << (8 * i);
                }
            }
            for i in 0..3 {
                if op & (0x10 << i) != 0 {
                    let b = *delta.get(pos).ok_or_else(|| Error::corrupt("truncated copy"))?;
                    pos += 1;
                    size |= (b as usize) << (8 * i);
                }
            }
            if size == 0 {
                size = 0x10000;
            }
            let end = offset
                .checked_add(size)
                .filter(|&e| e <= base.len())
                .ok_or_else(|| Error::corrupt("delta copy out of range"))?;
            out.extend_from_slice(&base[offset..end]);
        } else if op != 0 {
            let n = op as usize;
            let chunk = delta
                .get(pos..pos + n)
                .ok_or_else(|| Error::corrupt("truncated delta insert"))?;
            out.extend_from_slice(chunk);
            pos += n;
        } else {
            return Err(Error::corrupt("invalid delta opcode 0"));
        }
        if out.len() as u64 > result_size {
            return Err(Error::corrupt("delta result longer than declared"));
        }
    }
    if out.len() as u64 != result_size {
        return Err(Error::corrupt("delta result size mismatch"));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_and_insert() {
        let base = b"hello world";
        let delta = [11, 12, 0x90, 5, 2, b'!', b'!', 0x91, 6, 5];
        assert_eq!(apply_delta(base, &delta).unwrap(), b"hello!!world");
    }

    #[test]
    fn zero_size_copy_means_64k() {
        let base = vec![7u8; 0x10000];
        let delta = [0x80, 0x80, 0x04, 0x80, 0x80, 0x04, 0x80];
        // sizes encoded 0x10000 = [0x80,0x80,0x04]
        assert_eq!(apply_delta(&base, &delta).unwrap(), base);
    }

    #[test]
    fn errors() {
        let base = b"abc";
        assert!(apply_delta(base, &[3, 1, 0]).is_err()); // opcode 0
        assert!(apply_delta(base, &[3, 3, 0x90, 4]).is_err()); // copy past end
        assert!(apply_delta(base, &[3, 4, 0x90, 3]).is_err()); // wrong result size
        assert!(apply_delta(base, &[2, 3, 0x90, 3]).is_err()); // wrong base size
        assert!(apply_delta(base, &[3, 3, 5, b'a']).is_err()); // truncated insert
        assert!(apply_delta(base, &[3]).is_err());
    }
}
