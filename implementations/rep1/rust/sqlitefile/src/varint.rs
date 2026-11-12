//! SQLite variable-length integers (SPEC §1.3).

/// Decode a varint starting at `pos` in `buf`.
///
/// Returns the signed 64-bit value and the number of bytes consumed (1..=9),
/// or `None` if the buffer ends before the varint does.
pub fn read(buf: &[u8], pos: usize) -> Option<(i64, usize)> {
    let mut v: u64 = 0;
    for i in 0..8 {
        let b = *buf.get(pos.checked_add(i)?)?;
        v = (v << 7) | u64::from(b & 0x7f);
        if b & 0x80 == 0 {
            return Some((v as i64, i + 1));
        }
    }
    let b = *buf.get(pos.checked_add(8)?)?;
    v = (v << 8) | u64::from(b);
    Some((v as i64, 9))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_byte() {
        assert_eq!(read(&[0x00], 0), Some((0, 1)));
        assert_eq!(read(&[0x7f], 0), Some((127, 1)));
    }

    #[test]
    fn multi_byte() {
        assert_eq!(read(&[0x81, 0x00], 0), Some((128, 2)));
        assert_eq!(read(&[0xff, 0x7f], 0), Some((16383, 2)));
    }

    #[test]
    fn nine_bytes_negative() {
        let buf = [0xff; 9];
        assert_eq!(read(&buf, 0), Some((-1, 9)));
        let min = [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00];
        assert_eq!(read(&min, 0), Some((0, 9)));
    }

    #[test]
    fn offset_and_truncation() {
        assert_eq!(read(&[9, 0x05], 1), Some((5, 1)));
        assert_eq!(read(&[0x80], 0), None);
        assert_eq!(read(&[], 0), None);
    }
}
