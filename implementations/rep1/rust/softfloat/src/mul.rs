//! Multiplication.

use crate::format::{classify, inf, sign, unpack, zero, Class, QNAN};
use crate::round::round_pack;

/// Returns `a * b`, rounded to nearest-even.
pub fn mul(a: u32, b: u32) -> u32 {
    let s = sign(a) ^ sign(b);
    match (classify(a), classify(b)) {
        (Class::Nan, _) | (_, Class::Nan) => QNAN,
        (Class::Inf, Class::Zero) | (Class::Zero, Class::Inf) => QNAN,
        (Class::Inf, _) | (_, Class::Inf) => inf(s),
        (Class::Zero, _) | (_, Class::Zero) => zero(s),
        (Class::Finite, Class::Finite) => {
            let (x, y) = (unpack(a), unpack(b));
            // The exact product of the two 24-bit significands (< 2^48).
            let p = x.sig as u64 * y.sig as u64;
            round_pack(s, x.exp + y.exp - 46, p, false)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basics() {
        assert_eq!(mul(0x4040_0000, 0xc040_0000), 0xc110_0000);
        assert_eq!(mul(0x0000_0001, 0x3f00_0000), 0);
        assert_eq!(mul(0x8000_0001, 0x3f00_0000), 0x8000_0000);
        assert_eq!(mul(0x7f80_0000, 0), QNAN);
        assert_eq!(mul(0, 0xbf80_0000), 0x8000_0000);
        assert_eq!(mul(0x8000_0000, 0x8000_0000), 0);
        assert_eq!(mul(0x7f7f_ffff, 0x7f7f_ffff), 0x7f80_0000);
    }
}
