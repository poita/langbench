//! Square root.

use crate::format::{classify, sign, unpack, Class, QNAN};
use crate::round::round_pack;

/// Returns the square root of `a`, rounded to nearest-even.
pub fn sqrt(a: u32) -> u32 {
    match classify(a) {
        Class::Nan => QNAN,
        Class::Zero => a, // sqrt(+-0) = +-0
        _ if sign(a) => QNAN,
        Class::Inf => a,
        Class::Finite => {
            let x = unpack(a);
            // value = sig * 2^(exp - 23). Scale the significand by 2^shift so
            // that the remaining exponent is even; the root then has at
            // least 26 bits.
            let shift = if x.exp & 1 == 1 { 28 } else { 29 };
            let radicand = (x.sig as u64) << shift;
            let (root, remainder) = isqrt(radicand);
            let exp = (x.exp - 23 - shift as i32) / 2;
            round_pack(false, exp, root, remainder != 0)
        }
    }
}

/// Restoring digit-by-digit integer square root: returns `(r, n - r*r)` where
/// `r = floor(sqrt(n))`. Takes at most 32 steps for the inputs used here.
pub fn isqrt(mut n: u64) -> (u64, u64) {
    let mut root = 0u64;
    let mut bit = 1u64 << 62;
    while bit > n {
        bit >>= 2;
    }
    while bit != 0 {
        if n >= root + bit {
            n -= root + bit;
            root = (root >> 1) + bit;
        } else {
            root >>= 1;
        }
        bit >>= 2;
    }
    (root, n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isqrt_small() {
        for n in 0u64..2000 {
            let (r, rem) = isqrt(n);
            assert!(r * r <= n && (r + 1) * (r + 1) > n);
            assert_eq!(rem, n - r * r);
        }
    }

    #[test]
    fn basics() {
        assert_eq!(sqrt(0x4000_0000), 0x3fb5_04f3);
        assert_eq!(sqrt(0x3f80_0000), 0x3f80_0000);
        assert_eq!(sqrt(0x4080_0000), 0x4000_0000);
        assert_eq!(sqrt(0x8000_0000), 0x8000_0000);
        assert_eq!(sqrt(0), 0);
        assert_eq!(sqrt(0xbf80_0000), QNAN);
        assert_eq!(sqrt(0xff80_0000), QNAN);
        assert_eq!(sqrt(0x7f80_0000), 0x7f80_0000);
        assert_eq!(sqrt(0x7fa0_0000), QNAN);
        assert_eq!(sqrt(0x0000_0001), 0x1a35_04f3);
    }
}
