//! Lowercase hexadecimal conversion.

use crate::error::{Error, Result};

const DIGITS: &[u8; 16] = b"0123456789abcdef";

/// Appends the lowercase hex form of `bytes` to `out`.
pub fn encode_into(bytes: &[u8], out: &mut String) {
    out.reserve(bytes.len() * 2);
    for &b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 15) as usize] as char);
    }
}

/// Returns the lowercase hex form of `bytes`.
pub fn encode(bytes: &[u8]) -> String {
    let mut s = String::new();
    encode_into(bytes, &mut s);
    s
}

/// The value of a lowercase hex digit (`0-9a-f`), or `None`.
pub(crate) fn digit_value(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    }
}

/// Decodes a string of lowercase hex digits. Uppercase digits, odd lengths
/// and other characters are rejected.
pub fn decode(text: &[u8]) -> Result<Vec<u8>> {
    if text.len() % 2 != 0 {
        return Err(Error::Hex("odd number of digits"));
    }
    let mut out = Vec::with_capacity(text.len() / 2);
    for pair in text.chunks_exact(2) {
        match (digit_value(pair[0]), digit_value(pair[1])) {
            (Some(h), Some(l)) => out.push(h << 4 | l),
            _ => return Err(Error::Hex("not a lowercase hex digit")),
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        assert_eq!(encode(&[0x00, 0xff, 0x1a]), "00ff1a");
        assert_eq!(decode(b"00ff1a").unwrap(), vec![0x00, 0xff, 0x1a]);
        assert_eq!(decode(b"").unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn rejects_bad_input() {
        assert!(decode(b"0").is_err());
        assert!(decode(b"0A").is_err());
        assert!(decode(b"zz").is_err());
        assert!(decode(b"0 ").is_err());
    }
}
