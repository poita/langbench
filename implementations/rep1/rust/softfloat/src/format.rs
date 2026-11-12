//! binary32 field layout, classification and unpacking.

/// The canonical quiet NaN, the only NaN this crate ever produces.
pub const QNAN: u32 = 0x7fc0_0000;

/// Sign bit mask.
pub const SIGN_MASK: u32 = 0x8000_0000;

/// Bit pattern of positive infinity.
pub const INF: u32 = 0x7f80_0000;

/// Number of explicit fraction bits.
pub const FRAC_BITS: u32 = 23;

/// Exponent bias.
pub const BIAS: i32 = 127;

/// Coarse classification of a binary32 bit pattern.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    /// Positive or negative zero.
    Zero,
    /// Nonzero finite value (normal or denormal).
    Finite,
    /// Positive or negative infinity.
    Inf,
    /// Any NaN, quiet or signaling, with any payload.
    Nan,
}

/// Classifies a bit pattern.
pub fn classify(bits: u32) -> Class {
    let exp = (bits >> FRAC_BITS) & 0xff;
    let frac = bits & 0x007f_ffff;
    match (exp, frac) {
        (0, 0) => Class::Zero,
        (0xff, 0) => Class::Inf,
        (0xff, _) => Class::Nan,
        _ => Class::Finite,
    }
}

/// Returns `true` if the sign bit is set.
pub fn sign(bits: u32) -> bool {
    bits & SIGN_MASK != 0
}

/// Builds a signed infinity.
pub fn inf(sign: bool) -> u32 {
    INF | ((sign as u32) << 31)
}

/// Builds a signed zero.
pub fn zero(sign: bool) -> u32 {
    (sign as u32) << 31
}

/// A nonzero finite value as `sig * 2^(exp - 23)`, with `sig` normalised to
/// `2^23 <= sig < 2^24` (denormals are shifted up and the exponent lowered).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unpacked {
    /// Sign bit.
    pub sign: bool,
    /// Unbiased exponent of the leading bit.
    pub exp: i32,
    /// 24-bit significand with the leading bit at bit 23.
    pub sig: u32,
}

/// Unpacks a nonzero finite bit pattern. The result is unspecified for zero,
/// infinities and NaNs.
pub fn unpack(bits: u32) -> Unpacked {
    let e = ((bits >> FRAC_BITS) & 0xff) as i32;
    let frac = bits & 0x007f_ffff;
    let (mut sig, mut exp) = if e == 0 {
        (frac, 1 - BIAS)
    } else {
        (frac | 0x0080_0000, e - BIAS)
    };
    if sig != 0 && sig < 0x0080_0000 {
        let shift = sig.leading_zeros() - 8;
        sig <<= shift;
        exp -= shift as i32;
    }
    Unpacked { sign: sign(bits), exp, sig }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classification() {
        assert_eq!(classify(0), Class::Zero);
        assert_eq!(classify(0x8000_0000), Class::Zero);
        assert_eq!(classify(1), Class::Finite);
        assert_eq!(classify(0x7f7f_ffff), Class::Finite);
        assert_eq!(classify(0x7f80_0000), Class::Inf);
        assert_eq!(classify(0xff80_0000), Class::Inf);
        assert_eq!(classify(0x7f80_0001), Class::Nan);
        assert_eq!(classify(0xffff_ffff), Class::Nan);
    }

    #[test]
    fn unpack_normal_and_denormal() {
        let one = unpack(0x3f80_0000);
        assert_eq!((one.sign, one.exp, one.sig), (false, 0, 0x0080_0000));
        let d = unpack(0x8000_0001);
        assert_eq!((d.sign, d.exp, d.sig), (true, -149, 0x0080_0000));
    }
}
