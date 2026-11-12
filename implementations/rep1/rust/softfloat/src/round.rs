//! The shared round-and-pack step.
//!
//! Every operation produces a truncated integer significand plus a sticky
//! flag; [`round_pack`] rounds it exactly once, to nearest-even, directly onto
//! the binary32 grid (normal or denormal) and assembles the bit pattern.

use crate::format::{inf, zero, BIAS, FRAC_BITS};

/// Rounds and packs `(sig + epsilon) * 2^exp`, where `epsilon` is a value in
/// `(0, 1)` if `sticky` is set and zero otherwise.
///
/// `sig` must be nonzero and must carry enough low bits that the sticky
/// information lies well below the rounding position (at least 26 significant
/// bits, which every caller guarantees). The result is correctly rounded for
/// the given sign, including overflow to infinity and gradual underflow.
pub fn round_pack(sign: bool, exp: i32, sig: u64, sticky: bool) -> u32 {
    debug_assert!(sig != 0);
    // Normalise so the leading bit is bit 62 and fold the sticky flag into
    // bit 0. Bit 0 is far below the rounding position, so it only acts as a
    // "something nonzero below" marker.
    let lz = sig.leading_zeros() as i32; // >= 1 as callers keep sig < 2^63
    let sig = (sig << (lz - 1)) | sticky as u64;
    // value = sig * 2^(exp - (lz - 1)); the leading bit has weight 2^e.
    let e = exp + (63 - lz);
    let biased = e + BIAS;

    if biased >= 0xff {
        return inf(sign);
    }

    // Number of low bits of `sig` to discard: 62 - 23 = 39 for normals, more
    // for denormals, whose grid spacing is fixed at 2^-149.
    let shift = 62 - FRAC_BITS as i32 + if biased >= 1 { 0 } else { 1 - biased };
    if shift >= 64 {
        // Below half the smallest denormal: rounds to zero.
        return zero(sign);
    }
    let shift = shift as u32;
    let mut q = sig >> shift;
    let rem = sig & ((1u64 << shift) - 1);
    let half = 1u64 << (shift - 1);
    if rem > half || (rem == half && q & 1 == 1) {
        q += 1;
    }

    // For normals `q` includes the implicit bit, which carries into the
    // exponent field once the exponent is added in with `+`. For denormals
    // the base is zero, and rounding up to 2^23 gives the smallest normal.
    let base = if biased >= 1 { ((biased - 1) as u64) << FRAC_BITS } else { 0 };
    let bits = base + q;
    if bits >= 0x7f80_0000 {
        return inf(sign);
    }
    bits as u32 | ((sign as u32) << 31)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_values() {
        // 1.0 = 2^23 * 2^-23
        assert_eq!(round_pack(false, -23, 1 << 23, false), 0x3f80_0000);
        assert_eq!(round_pack(true, -23, 1 << 23, false), 0xbf80_0000);
    }

    #[test]
    fn ties_to_even() {
        // 1 + 2^-24 (tie, even is 1.0) and (1+2^-23) + 2^-24 (even is 1+2^-22).
        assert_eq!(round_pack(false, -24, (1 << 24) + 1, false), 0x3f80_0000);
        assert_eq!(round_pack(false, -24, (1 << 24) + 3, false), 0x3f80_0002);
        // A sticky bit breaks the tie upward.
        assert_eq!(round_pack(false, -24, (1 << 24) + 1, true), 0x3f80_0001);
    }

    #[test]
    fn denormal_and_underflow() {
        // The smallest denormal, 2^-149, is exact.
        assert_eq!(round_pack(false, -149, 1, false), 1);
        // Half the smallest denormal ties to zero; with sticky it rounds up.
        assert_eq!(round_pack(false, -150, 1, false), 0);
        assert_eq!(round_pack(false, -150, 1, true), 1);
        // 1.5 * 2^-149 ties to even, i.e. 2 * 2^-149.
        assert_eq!(round_pack(false, -150, 3, false), 2);
        assert_eq!(round_pack(true, -300, 1 << 30, false), 0x8000_0000);
    }

    #[test]
    fn overflow() {
        assert_eq!(round_pack(false, 104, 1 << 24, false), 0x7f80_0000); // 2^128
        assert_eq!(round_pack(true, 100, 1 << 40, false), 0xff80_0000);
    }

    #[test]
    fn denormal_rounds_up_to_min_normal() {
        // (2^23 - 0.25) * 2^-149
        assert_eq!(round_pack(false, -151, (1u64 << 25) - 1, false), 0x0080_0000);
    }
}
