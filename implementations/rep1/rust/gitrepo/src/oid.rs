//! Object ids.

use std::fmt;

/// A 20-byte SHA-1 object id.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ObjectId([u8; 20]);

impl ObjectId {
    /// The all-zero id, used for "no object" in diffs.
    pub const ZERO: ObjectId = ObjectId([0; 20]);

    /// Wraps 20 raw bytes.
    pub fn from_bytes(bytes: [u8; 20]) -> ObjectId {
        ObjectId(bytes)
    }

    /// Builds an id from a slice, which must be exactly 20 bytes long.
    pub fn from_slice(bytes: &[u8]) -> Option<ObjectId> {
        bytes.try_into().ok().map(ObjectId)
    }

    /// Parses exactly 40 *lowercase* hexadecimal digits.
    pub fn from_hex(hex: &[u8]) -> Option<ObjectId> {
        if hex.len() != 40 {
            return None;
        }
        let mut out = [0u8; 20];
        for (i, pair) in hex.chunks(2).enumerate() {
            out[i] = (nibble(pair[0])? << 4) | nibble(pair[1])?;
        }
        Some(ObjectId(out))
    }

    /// The raw bytes of the id.
    pub fn as_bytes(&self) -> &[u8; 20] {
        &self.0
    }

    /// The id as 40 lowercase hexadecimal digits.
    pub fn to_hex(&self) -> String {
        const DIGITS: &[u8; 16] = b"0123456789abcdef";
        let mut s = String::with_capacity(40);
        for b in self.0 {
            s.push(DIGITS[(b >> 4) as usize] as char);
            s.push(DIGITS[(b & 15) as usize] as char);
        }
        s
    }
}

/// Value of a lowercase hexadecimal digit.
fn nibble(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    }
}

impl fmt::Display for ObjectId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_hex())
    }
}

impl fmt::Debug for ObjectId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ObjectId({})", self.to_hex())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trip() {
        let hex = "b7814cae2e925fe74c6cd5816462fff515ccb256";
        let id = ObjectId::from_hex(hex.as_bytes()).unwrap();
        assert_eq!(id.to_hex(), hex);
        assert_eq!(id.to_string(), hex);
    }

    #[test]
    fn rejects_bad_hex() {
        assert!(ObjectId::from_hex(b"abc").is_none());
        assert!(ObjectId::from_hex(&[b'A'; 40]).is_none());
        assert!(ObjectId::from_hex(&[b'g'; 40]).is_none());
        assert!(ObjectId::from_slice(&[0; 19]).is_none());
    }
}
