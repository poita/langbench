//! Lowercase hexadecimal codec.
//!
//! The command protocol writes byte strings as lowercase hex, using `-` for
//! the empty string; [`encode_or_dash`] and [`decode_arg`] implement that
//! convention.

const DIGITS: &[u8; 16] = b"0123456789abcdef";

/// Encodes bytes as lowercase hex (empty input gives an empty string).
pub fn encode(data: &[u8]) -> String {
    let mut s = String::with_capacity(data.len() * 2);
    for &b in data {
        s.push(DIGITS[(b >> 4) as usize] as char);
        s.push(DIGITS[(b & 15) as usize] as char);
    }
    s
}

/// Encodes bytes as lowercase hex, or `-` if there are none.
pub fn encode_or_dash(data: &[u8]) -> String {
    if data.is_empty() {
        "-".to_string()
    } else {
        encode(data)
    }
}

fn nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    }
}

/// Decodes an even-length run of lowercase hex digits (possibly empty).
pub fn decode(text: &[u8]) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    text.chunks_exact(2)
        .map(|p| Some((nibble(p[0])? << 4) | nibble(p[1])?))
        .collect()
}

/// Decodes a protocol byte-string argument: `-` is the empty string, anything
/// else must be a non-empty, even-length run of lowercase hex digits.
pub fn decode_arg(field: &[u8]) -> Option<Vec<u8>> {
    match field {
        [] => None,
        b"-" => Some(Vec::new()),
        _ => decode(field),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        assert_eq!(encode(&[0, 15, 16, 255]), "000f10ff");
        assert_eq!(decode(b"000f10ff").unwrap(), vec![0, 15, 16, 255]);
    }

    #[test]
    fn rejects_bad_input() {
        assert!(decode(b"abc").is_none());
        assert!(decode(b"AB").is_none());
        assert!(decode(b"zz").is_none());
        assert!(decode_arg(b"").is_none());
        assert_eq!(decode_arg(b"-").unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn dash_for_empty() {
        assert_eq!(encode_or_dash(&[]), "-");
        assert_eq!(encode_or_dash(&[1]), "01");
    }
}
