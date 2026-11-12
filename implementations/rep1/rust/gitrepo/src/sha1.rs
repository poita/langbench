//! SHA-1 (FIPS 180-4).

use crate::oid::ObjectId;

/// An incremental SHA-1 hasher.
#[derive(Clone)]
pub struct Sha1 {
    state: [u32; 5],
    block: [u8; 64],
    filled: usize,
    length: u64,
}

impl Default for Sha1 {
    fn default() -> Self {
        Sha1::new()
    }
}

impl Sha1 {
    /// Creates a hasher with the standard initial state.
    pub fn new() -> Sha1 {
        Sha1 {
            state: [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0],
            block: [0; 64],
            filled: 0,
            length: 0,
        }
    }

    /// Feeds more bytes into the hash.
    pub fn update(&mut self, mut data: &[u8]) {
        self.length = self.length.wrapping_add(data.len() as u64);
        if self.filled > 0 {
            let take = (64 - self.filled).min(data.len());
            self.block[self.filled..self.filled + take].copy_from_slice(&data[..take]);
            self.filled += take;
            data = &data[take..];
            if self.filled < 64 {
                return;
            }
            let block = self.block;
            self.compress(&block);
            self.filled = 0;
        }
        while data.len() >= 64 {
            let (head, rest) = data.split_at(64);
            self.compress(head.try_into().unwrap());
            data = rest;
        }
        self.block[..data.len()].copy_from_slice(data);
        self.filled = data.len();
    }

    /// Finishes the hash and returns the 20-byte digest.
    pub fn finish(mut self) -> [u8; 20] {
        let bit_length = self.length.wrapping_mul(8);
        let mut pad = vec![0x80u8];
        let zeros = (119 - self.filled) % 64;
        pad.extend(std::iter::repeat(0).take(zeros));
        pad.extend_from_slice(&bit_length.to_be_bytes());
        self.update(&pad);
        debug_assert_eq!(self.filled, 0);
        let mut out = [0u8; 20];
        for (chunk, word) in out.chunks_mut(4).zip(self.state) {
            chunk.copy_from_slice(&word.to_be_bytes());
        }
        out
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let mut w = [0u32; 80];
        for (i, chunk) in block.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes(chunk.try_into().unwrap());
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = self.state;
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let t = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = t;
        }
        for (s, v) in self.state.iter_mut().zip([a, b, c, d, e]) {
            *s = s.wrapping_add(v);
        }
    }
}

/// Hashes a byte string in one go.
pub fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h = Sha1::new();
    h.update(data);
    h.finish()
}

/// Computes the id of an object from its type name and payload, i.e. the
/// SHA-1 of `<type> SP <size> NUL <payload>`.
pub fn hash_object(type_name: &str, payload: &[u8]) -> ObjectId {
    let mut h = Sha1::new();
    h.update(type_name.as_bytes());
    h.update(b" ");
    h.update(payload.len().to_string().as_bytes());
    h.update(&[0]);
    h.update(payload);
    ObjectId::from_bytes(h.finish())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(d: [u8; 20]) -> String {
        ObjectId::from_bytes(d).to_hex()
    }

    #[test]
    fn standard_vectors() {
        assert_eq!(hex(sha1(b"")), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(hex(sha1(b"abc")), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(
            hex(sha1(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        );
    }

    #[test]
    fn million_a() {
        let data = vec![b'a'; 1_000_000];
        assert_eq!(hex(sha1(&data)), "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
    }

    #[test]
    fn incremental_matches_one_shot() {
        let data: Vec<u8> = (0..1000u32).map(|i| (i * 7) as u8).collect();
        for step in [1, 3, 63, 64, 65, 200] {
            let mut h = Sha1::new();
            for c in data.chunks(step) {
                h.update(c);
            }
            assert_eq!(h.finish(), sha1(&data), "step {step}");
        }
    }

    #[test]
    fn object_id_of_blob() {
        assert_eq!(
            hash_object("blob", b"one file\n").to_hex(),
            "b7814cae2e925fe74c6cd5816462fff515ccb256"
        );
    }
}
