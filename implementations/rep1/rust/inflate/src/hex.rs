//! Hexadecimal encoding and decoding.

use std::fmt;

/// Error from [`decode`]: the text is not valid hexadecimal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HexError;

impl fmt::Display for HexError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid hexadecimal input")
    }
}

impl std::error::Error for HexError {}

fn nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Decodes hex text (either case, two digits per byte) into bytes.
/// Surrounding ASCII whitespace is ignored.
pub fn decode(text: &[u8]) -> Result<Vec<u8>, HexError> {
    let text = text.trim_ascii();
    if !text.len().is_multiple_of(2) {
        return Err(HexError);
    }
    text.chunks_exact(2)
        .map(|p| Ok(nibble(p[0]).ok_or(HexError)? << 4 | nibble(p[1]).ok_or(HexError)?))
        .collect()
}

/// Encodes bytes as lowercase hex, two digits per byte.
pub fn encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = Vec::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(DIGITS[(b >> 4) as usize]);
        out.push(DIGITS[(b & 15) as usize]);
    }
    String::from_utf8(out).expect("hex digits are ASCII")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let bytes = [0u8, 1, 0xab, 0xff];
        assert_eq!(encode(&bytes), "0001abff");
        assert_eq!(decode(b"0001ABff\n").unwrap(), bytes);
    }

    #[test]
    fn empty_and_invalid() {
        assert_eq!(decode(b"\n").unwrap(), Vec::<u8>::new());
        assert!(decode(b"abc").is_err());
        assert!(decode(b"zz").is_err());
    }
}
