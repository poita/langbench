//! 64-bit FNV-1a content hashing.

const OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const PRIME: u64 = 0x0000_0100_0000_01b3;

/// Computes the 64-bit FNV-1a hash of `bytes`.
///
/// ```
/// assert_eq!(kiln::hash::fnv1a64(b""), 0xcbf29ce484222325);
/// assert_eq!(kiln::hash::hex(kiln::hash::fnv1a64(b"hello\n")), "a9bc80cca21f28b3");
/// ```
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h = OFFSET_BASIS;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(PRIME);
    }
    h
}

/// Formats a hash as exactly 16 lowercase hexadecimal digits.
pub fn hex(h: u64) -> String {
    format!("{h:016x}")
}

/// Parses exactly 16 lowercase hexadecimal digits.
pub fn parse_hex(s: &[u8]) -> Option<u64> {
    if s.len() != 16 {
        return None;
    }
    let mut v = 0u64;
    for &b in s {
        let d = match b {
            b'0'..=b'9' => b - b'0',
            b'a'..=b'f' => b - b'a' + 10,
            _ => return None,
        };
        v = (v << 4) | u64::from(d);
    }
    Some(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_vectors() {
        assert_eq!(hex(fnv1a64(b"")), "cbf29ce484222325");
        assert_eq!(hex(fnv1a64(b"hello\n")), "a9bc80cca21f28b3");
        assert_eq!(hex(fnv1a64(b"abc\n")), "fc17b183ee074373");
    }

    #[test]
    fn hex_roundtrip() {
        assert_eq!(parse_hex(b"a9bc80cca21f28b3"), Some(0xa9bc80cca21f28b3));
        assert_eq!(parse_hex(b"A9bc80cca21f28b3"), None);
        assert_eq!(parse_hex(b"a9bc80cca21f28b"), None);
    }
}
