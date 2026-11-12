//! Addition and subtraction.

use crate::format::{classify, sign, unpack, zero, Class, QNAN, SIGN_MASK};
use crate::round::round_pack;

/// Guard bits appended below the 24-bit significands before alignment.
const GUARD: u32 = 29;

/// Returns `a + b`, rounded to nearest-even.
pub fn add(a: u32, b: u32) -> u32 {
    match (classify(a), classify(b)) {
        (Class::Nan, _) | (_, Class::Nan) => QNAN,
        (Class::Inf, Class::Inf) => {
            if sign(a) == sign(b) {
                a
            } else {
                QNAN
            }
        }
        (Class::Inf, _) => a,
        (_, Class::Inf) => b,
        (Class::Zero, Class::Zero) => zero(sign(a) && sign(b)),
        (Class::Zero, _) => b,
        (_, Class::Zero) => a,
        (Class::Finite, Class::Finite) => add_finite(a, b),
    }
}

/// Returns `a - b`, rounded to nearest-even; identical to `add(a, -b)`.
pub fn sub(a: u32, b: u32) -> u32 {
    // Flipping the sign of a NaN is harmless: any NaN gives `QNAN`.
    add(a, b ^ SIGN_MASK)
}

/// Sum of two nonzero finite values.
fn add_finite(a: u32, b: u32) -> u32 {
    let (mut x, mut y) = (unpack(a), unpack(b));
    // Make `x` the operand of larger magnitude.
    if (y.exp, y.sig) > (x.exp, x.sig) {
        std::mem::swap(&mut x, &mut y);
    }

    let xs = (x.sig as u64) << GUARD;
    let ys_full = (y.sig as u64) << GUARD;
    let d = (x.exp - y.exp) as u32;
    // Align the smaller operand, folding the bits shifted out into a sticky
    // bit in the lowest position.
    let ys = if d == 0 {
        ys_full
    } else if d >= 64 {
        1
    } else {
        (ys_full >> d) | (ys_full & ((1u64 << d) - 1) != 0) as u64
    };

    let sum = if x.sign == y.sign {
        xs + ys
    } else {
        xs - ys
    };
    if sum == 0 {
        return zero(false); // exact cancellation gives +0
    }
    // value = sum * 2^(x.exp - 23 - GUARD); the sticky bit is already folded
    // into `sum`, and is only ever set when at most one bit can cancel.
    round_pack(x.sign, x.exp - 23 - GUARD as i32, sum, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basics() {
        assert_eq!(add(0x3f80_0000, 0x3f80_0000), 0x4000_0000);
        assert_eq!(sub(0x3f80_0000, 0x3f80_0000), 0);
        assert_eq!(add(0x7f7f_ffff, 0x7300_0000), 0x7f80_0000);
        assert_eq!(add(0x7f7f_ffff, 0x72ff_ffff), 0x7f7f_ffff);
        assert_eq!(add(0x3f80_0000, 0x3380_0000), 0x3f80_0000);
        assert_eq!(add(0x3f80_0001, 0x3380_0000), 0x3f80_0002);
    }

    #[test]
    fn signed_zeros_and_specials() {
        assert_eq!(add(0x8000_0000, 0x8000_0000), 0x8000_0000);
        assert_eq!(add(0x8000_0000, 0), 0);
        assert_eq!(sub(0x8000_0000, 0), 0x8000_0000);
        assert_eq!(sub(0x8000_0000, 0x8000_0000), 0);
        assert_eq!(add(0x8000_0000, 0x3f80_0000), 0x3f80_0000);
        assert_eq!(add(0x7f80_0000, 0xff80_0000), QNAN);
        assert_eq!(sub(0x7f80_0000, 0x7f80_0000), QNAN);
        assert_eq!(add(0x7f80_0000, 0x3f80_0000), 0x7f80_0000);
        assert_eq!(add(0x7fc1_2345, 0x3f80_0000), QNAN);
    }
}
