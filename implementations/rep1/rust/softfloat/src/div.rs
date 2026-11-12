//! Division.

use crate::format::{classify, inf, sign, unpack, zero, Class, QNAN};
use crate::round::round_pack;

/// Returns `a / b`, rounded to nearest-even.
pub fn div(a: u32, b: u32) -> u32 {
    let s = sign(a) ^ sign(b);
    match (classify(a), classify(b)) {
        (Class::Nan, _) | (_, Class::Nan) => QNAN,
        (Class::Inf, Class::Inf) | (Class::Zero, Class::Zero) => QNAN,
        (Class::Inf, _) => inf(s),
        (_, Class::Inf) => zero(s),
        (_, Class::Zero) => inf(s),
        (Class::Zero, _) => zero(s),
        (Class::Finite, Class::Finite) => {
            // Both significands are normalised to [2^23, 2^24), so the
            // quotient below lies in (2^25, 2^27): at least 26 bits.
            let (x, y) = (unpack(a), unpack(b));
            let num = (x.sig as u64) << 26;
            let den = y.sig as u64;
            let q = num / den;
            let sticky = num % den != 0;
            round_pack(s, x.exp - y.exp - 26, q, sticky)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basics() {
        assert_eq!(div(0x3f80_0000, 0x4040_0000), 0x3eaa_aaab);
        assert_eq!(div(0x0000_0001, 0x4000_0000), 0);
        assert_eq!(div(0x0000_0003, 0x4000_0000), 2);
        assert_eq!(div(0x3f80_0000, 0x8000_0000), 0xff80_0000);
        assert_eq!(div(0, 0), QNAN);
        assert_eq!(div(0x7f80_0000, 0x7f80_0000), QNAN);
        assert_eq!(div(0x3f80_0000, 0xff80_0000), 0x8000_0000);
        assert_eq!(div(0x8000_0000, 0x7f80_0000), 0x8000_0000);
    }
}
