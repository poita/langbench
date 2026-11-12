//! 64-bit FNV-1a content hashing.

const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const PRIME: u64 = 0x0000_0100_0000_01b3;

/// Hashes a byte string with 64-bit FNV-1a.
pub fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h = OFFSET;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(PRIME);
    }
    h
}

/// Renders a hash as exactly 16 lowercase hexadecimal digits.
pub fn hex(h: u64) -> String {
    format!("{h:016x}")
}

/// Parses exactly 16 lowercase hexadecimal digits.
pub fn parse_hex(s: &[u8]) -> Option<u64> {
    if s.len() != 16 {
        return None;
    }
    let mut v: u64 = 0;
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
    fn known_values() {
        assert_eq!(hex(fnv1a(b"")), "cbf29ce484222325");
        assert_eq!(hex(fnv1a(b"hello\n")), "a9bc80cca21f28b3");
        assert_eq!(hex(fnv1a(b"abc\n")), "fc17b183ee074373");
    }

    #[test]
    fn hex_roundtrip() {
        assert_eq!(parse_hex(b"a9bc80cca21f28b3"), Some(0xa9bc_80cc_a21f_28b3));
        assert_eq!(parse_hex(b"A9bc80cca21f28b3"), None);
        assert_eq!(parse_hex(b"a9bc"), None);
    }
}
