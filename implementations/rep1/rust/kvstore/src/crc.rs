//! CRC-32 (reflected polynomial `0xEDB88320`, init and final XOR `0xFFFFFFFF`).
//!
//! ```
//! assert_eq!(tessera::crc::crc32(b"123456789"), 0xCBF4_3926);
//! ```

const fn make_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
            bit += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
}

static TABLE: [u32; 256] = make_table();

/// An incremental CRC-32 computation.
#[derive(Clone, Copy, Debug)]
pub struct Crc32 {
    state: u32,
}

impl Default for Crc32 {
    fn default() -> Self {
        Self::new()
    }
}

impl Crc32 {
    /// Starts a new checksum.
    pub fn new() -> Self {
        Crc32 { state: 0xFFFF_FFFF }
    }

    /// Feeds more bytes.
    pub fn update(&mut self, data: &[u8]) {
        let mut crc = self.state;
        for &b in data {
            crc = TABLE[((crc ^ b as u32) & 0xFF) as usize] ^ (crc >> 8);
        }
        self.state = crc;
    }

    /// Returns the checksum of everything fed so far.
    pub fn finish(&self) -> u32 {
        self.state ^ 0xFFFF_FFFF
    }
}

/// CRC-32 of `data`.
pub fn crc32(data: &[u8]) -> u32 {
    let mut c = Crc32::new();
    c.update(data);
    c.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_vectors() {
        assert_eq!(crc32(b""), 0);
        assert_eq!(crc32(b"a"), 0xE8B7_BE43);
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b"TESSERA1"), 0x2C9A_9B66);
        assert_eq!(crc32(b"TESSWAL1"), 0x7D44_6716);
        assert_eq!(crc32(&[0u8; 20]), 0x0FD5_9B8D);
        assert_eq!(crc32(&[0u8; 1024]), 0xEFB5_AF2E);
    }

    #[test]
    fn incremental_matches_one_shot() {
        let mut c = Crc32::new();
        c.update(b"1234");
        c.update(b"56789");
        assert_eq!(c.finish(), 0xCBF4_3926);
    }
}
