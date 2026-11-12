//! Adler-32 checksum.

/// Computes the Adler-32 checksum of `data`.
pub fn adler32(data: &[u8]) -> u32 {
    const MOD: u32 = 65521;
    let (mut a, mut b) = (1u32, 0u32);
    for &x in data {
        a = (a + x as u32) % MOD;
        b = (b + a) % MOD;
    }
    (b << 16) | a
}

/// Formats the Adler-32 checksum of `data` as eight lower-case hex digits.
pub fn adler32_hex(data: &[u8]) -> String {
    format!("{:08x}", adler32(data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_values() {
        assert_eq!(adler32_hex(b""), "00000001");
        assert_eq!(adler32_hex(b"Wikipedia"), "11e60398");
        assert_eq!(adler32_hex(&[0, 1, 2, 3]), "000e0007");
    }
}
