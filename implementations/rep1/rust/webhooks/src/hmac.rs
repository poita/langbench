//! RFC 2104 HMAC-SHA-256.

use crate::sha256::{sha256, Sha256, BLOCK_LEN, DIGEST_LEN};

/// An HMAC-SHA-256 key with its inner and outer pad states precomputed.
///
/// Building the key hashes the two pad blocks once; every [`HmacKey::mac`]
/// call then only pays for the message and two final compressions. This makes
/// signing many messages with one key cheap.
///
/// ```
/// use webhooks::HmacKey;
/// let key = HmacKey::new(&[0x0b; 20]);
/// let mac = key.mac(b"Hi There");
/// assert_eq!(mac[0], 0xb0);
/// ```
#[derive(Clone, Debug)]
pub struct HmacKey {
    inner: Sha256,
    outer: Sha256,
}

impl HmacKey {
    /// Prepares a key of any length (including zero).
    pub fn new(key: &[u8]) -> Self {
        let mut block = [0u8; BLOCK_LEN];
        if key.len() > BLOCK_LEN {
            block[..DIGEST_LEN].copy_from_slice(&sha256(key));
        } else {
            block[..key.len()].copy_from_slice(key);
        }
        let mut ipad = [0u8; BLOCK_LEN];
        let mut opad = [0u8; BLOCK_LEN];
        for i in 0..BLOCK_LEN {
            ipad[i] = block[i] ^ 0x36;
            opad[i] = block[i] ^ 0x5c;
        }
        let mut inner = Sha256::new();
        inner.update(&ipad);
        let mut outer = Sha256::new();
        outer.update(&opad);
        HmacKey { inner, outer }
    }

    /// MAC of a single message.
    pub fn mac(&self, msg: &[u8]) -> [u8; DIGEST_LEN] {
        self.mac_parts(&[msg])
    }

    /// MAC of the concatenation of `parts`, without allocating it.
    pub fn mac_parts(&self, parts: &[&[u8]]) -> [u8; DIGEST_LEN] {
        let mut inner = self.inner.clone();
        for p in parts {
            inner.update(p);
        }
        let digest = inner.finalize();
        let mut outer = self.outer.clone();
        outer.update(&digest);
        outer.finalize()
    }
}

/// One-shot HMAC-SHA-256.
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; DIGEST_LEN] {
    HmacKey::new(key).mac(msg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    #[test]
    fn rfc4231_case_1() {
        assert_eq!(
            hex::encode(&hmac_sha256(&[0x0b; 20], b"Hi There")),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
    }

    #[test]
    fn rfc4231_case_2() {
        assert_eq!(
            hex::encode(&hmac_sha256(b"Jefe", b"what do ya want for nothing?")),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn rfc4231_long_key() {
        assert_eq!(
            hex::encode(&hmac_sha256(
                &[0xaa; 131],
                b"Test Using Larger Than Block-Size Key - Hash Key First"
            )),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        );
    }

    #[test]
    fn empty_key_equals_zero_block_key() {
        assert_eq!(hmac_sha256(b"", b"m"), hmac_sha256(&[0u8; 64], b"m"));
    }

    #[test]
    fn parts_equal_concatenation() {
        let k = HmacKey::new(b"key");
        assert_eq!(k.mac_parts(&[b"ab", b"", b"cd"]), k.mac(b"abcd"));
    }
}
