//! Unsigned arbitrary-precision integers.
//!
//! A [`Natural`] stores its value as little-endian limbs in base 10⁹
//! ([`BASE`]). The limb vector never has trailing (most significant) zero
//! limbs; zero is the empty vector.

use std::cmp::Ordering;
use std::fmt;

use crate::error::{ArithmeticError, ParseError};

/// The limb base: 10⁹, the largest power of ten whose square fits in a `u64`
/// with room for carries.
pub const BASE: u64 = 1_000_000_000;
/// Number of decimal digits per limb.
pub const LIMB_DIGITS: usize = 9;

/// A non-negative integer of arbitrary size.
#[derive(Clone, Default, PartialEq, Eq, Hash)]
pub struct Natural {
    /// Little-endian limbs, each `< BASE`, with no most-significant zero limb.
    limbs: Vec<u32>,
}

impl Natural {
    /// The value zero.
    pub fn zero() -> Natural {
        Natural { limbs: Vec::new() }
    }

    /// The value one.
    pub fn one() -> Natural {
        Natural::from(1u64)
    }

    /// Returns `true` if the value is zero.
    pub fn is_zero(&self) -> bool {
        self.limbs.is_empty()
    }

    /// Returns `true` if the value is odd (the base is even, so only the
    /// lowest limb matters).
    pub fn is_odd(&self) -> bool {
        self.limbs.first().is_some_and(|l| l % 2 == 1)
    }

    /// Builds a value from limbs, trimming leading zero limbs.
    fn from_limbs(mut limbs: Vec<u32>) -> Natural {
        while limbs.last() == Some(&0) {
            limbs.pop();
        }
        Natural { limbs }
    }

    /// Parses ASCII decimal digits (no sign). Leading zeros are accepted.
    ///
    /// Runs in time linear in the number of digits.
    pub fn from_decimal(s: &str) -> Result<Natural, ParseError> {
        let bytes = s.as_bytes();
        if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
            return Err(ParseError::InvalidNumber);
        }
        let mut limbs = Vec::with_capacity(bytes.len() / LIMB_DIGITS + 1);
        for chunk in bytes.rchunks(LIMB_DIGITS) {
            let limb = chunk
                .iter()
                .fold(0u32, |acc, &d| acc * 10 + u32::from(d - b'0'));
            limbs.push(limb);
        }
        Ok(Natural::from_limbs(limbs))
    }

    /// Returns the value as a `u64` if it fits.
    pub fn to_u64(&self) -> Option<u64> {
        // u64::MAX has 20 digits, so at most three limbs can fit.
        if self.limbs.len() > 3 {
            return None;
        }
        let mut acc: u64 = 0;
        for &l in self.limbs.iter().rev() {
            acc = acc.checked_mul(BASE)?.checked_add(u64::from(l))?;
        }
        Some(acc)
    }

    /// Returns `self + other`.
    pub fn add(&self, other: &Natural) -> Natural {
        let (long, short) = if self.limbs.len() >= other.limbs.len() {
            (&self.limbs, &other.limbs)
        } else {
            (&other.limbs, &self.limbs)
        };
        let mut out = Vec::with_capacity(long.len() + 1);
        let mut carry = 0u32;
        for (i, &l) in long.iter().enumerate() {
            let mut s = l + carry + short.get(i).copied().unwrap_or(0);
            if s >= BASE as u32 {
                s -= BASE as u32;
                carry = 1;
            } else {
                carry = 0;
            }
            out.push(s);
        }
        if carry > 0 {
            out.push(carry);
        }
        Natural { limbs: out }
    }

    /// Returns `self - other`, or `None` if `other > self`.
    pub fn checked_sub(&self, other: &Natural) -> Option<Natural> {
        if self.cmp(other) == Ordering::Less {
            return None;
        }
        let mut out = Vec::with_capacity(self.limbs.len());
        let mut borrow = 0i64;
        for (i, &l) in self.limbs.iter().enumerate() {
            let mut d = i64::from(l) - borrow - i64::from(other.limbs.get(i).copied().unwrap_or(0));
            if d < 0 {
                d += BASE as i64;
                borrow = 1;
            } else {
                borrow = 0;
            }
            out.push(d as u32);
        }
        debug_assert_eq!(borrow, 0);
        Some(Natural::from_limbs(out))
    }

    /// Returns `self * other` using schoolbook multiplication, O(n·m).
    pub fn mul(&self, other: &Natural) -> Natural {
        if self.is_zero() || other.is_zero() {
            return Natural::zero();
        }
        let (a, b) = (&self.limbs, &other.limbs);
        let mut out = vec![0u32; a.len() + b.len()];
        for (i, &x) in a.iter().enumerate() {
            if x == 0 {
                continue;
            }
            let x = u64::from(x);
            let mut carry = 0u64;
            for (j, &y) in b.iter().enumerate() {
                // x*y < 10^18, plus two values < 10^9: fits comfortably in u64.
                let cur = x * u64::from(y) + u64::from(out[i + j]) + carry;
                out[i + j] = (cur % BASE) as u32;
                carry = cur / BASE;
            }
            out[i + b.len()] = carry as u32; // slot untouched so far
        }
        Natural::from_limbs(out)
    }

    /// Divides by a single limb value `0 < d < BASE`, returning (quotient, remainder).
    fn div_rem_small(&self, d: u32) -> (Natural, u32) {
        let d = u64::from(d);
        let mut out = vec![0u32; self.limbs.len()];
        let mut rem = 0u64;
        for i in (0..self.limbs.len()).rev() {
            let cur = rem * BASE + u64::from(self.limbs[i]);
            out[i] = (cur / d) as u32;
            rem = cur % d;
        }
        (Natural::from_limbs(out), rem as u32)
    }

    /// Multiplies by a single limb value `< BASE`, returning limbs with exactly
    /// `len + 1` entries (not trimmed).
    fn mul_small_padded(limbs: &[u32], m: u64) -> Vec<u32> {
        let mut out = Vec::with_capacity(limbs.len() + 1);
        let mut carry = 0u64;
        for &l in limbs {
            let cur = u64::from(l) * m + carry;
            out.push((cur % BASE) as u32);
            carry = cur / BASE;
        }
        out.push(carry as u32);
        out
    }

    /// Computes quotient and remainder together (Knuth's Algorithm D).
    ///
    /// Returns [`ArithmeticError::DivisionByZero`] if `divisor` is zero.
    pub fn div_rem(&self, divisor: &Natural) -> Result<(Natural, Natural), ArithmeticError> {
        if divisor.is_zero() {
            return Err(ArithmeticError::DivisionByZero);
        }
        if self.cmp(divisor) == Ordering::Less {
            return Ok((Natural::zero(), self.clone()));
        }
        if divisor.limbs.len() == 1 {
            let (q, r) = self.div_rem_small(divisor.limbs[0]);
            return Ok((q, Natural::from(u64::from(r))));
        }

        let n = divisor.limbs.len();
        let m = self.limbs.len() - n;

        // D1: normalise so the divisor's top limb is >= BASE/2.
        let d = BASE / (u64::from(divisor.limbs[n - 1]) + 1);
        let mut u = Natural::mul_small_padded(&self.limbs, d); // m + n + 1 limbs
        let mut v = Natural::mul_small_padded(&divisor.limbs, d);
        debug_assert_eq!(v[n], 0);
        v.truncate(n);
        let (vt, vs) = (u64::from(v[n - 1]), u64::from(v[n - 2]));

        let mut q = vec![0u32; m + 1];
        for j in (0..=m).rev() {
            // D3: estimate the quotient digit from the top two limbs.
            let num = u64::from(u[j + n]) * BASE + u64::from(u[j + n - 1]);
            let mut qhat = num / vt;
            let mut rhat = num % vt;
            while qhat >= BASE || qhat * vs > rhat * BASE + u64::from(u[j + n - 2]) {
                qhat -= 1;
                rhat += vt;
                if rhat >= BASE {
                    break;
                }
            }

            // D4: multiply and subtract qhat * v from u[j..=j+n].
            let mut carry = 0u64;
            let mut borrow = 0i64;
            for i in 0..n {
                let p = qhat * u64::from(v[i]) + carry;
                carry = p / BASE;
                let mut t = i64::from(u[i + j]) - borrow - (p % BASE) as i64;
                if t < 0 {
                    t += BASE as i64;
                    borrow = 1;
                } else {
                    borrow = 0;
                }
                u[i + j] = t as u32;
            }
            let mut t = i64::from(u[j + n]) - borrow - carry as i64;
            if t < 0 {
                t += BASE as i64;
                borrow = 1;
            } else {
                borrow = 0;
            }
            u[j + n] = t as u32;

            // D5/D6: if the subtraction went negative, add the divisor back.
            if borrow != 0 {
                qhat -= 1;
                let mut c = 0u32;
                for i in 0..n {
                    let mut s = u[i + j] + v[i] + c;
                    if s >= BASE as u32 {
                        s -= BASE as u32;
                        c = 1;
                    } else {
                        c = 0;
                    }
                    u[i + j] = s;
                }
                // The carry out cancels the earlier borrow.
                u[j + n] = (u[j + n] + c) % BASE as u32;
            }
            q[j] = qhat as u32;
        }

        // D8: unnormalise the remainder.
        u.truncate(n);
        let (r, _) = Natural::from_limbs(u).div_rem_small(d as u32);
        Ok((Natural::from_limbs(q), r))
    }

    /// Returns `self` raised to the power `exp` by repeated squaring.
    pub fn pow(&self, mut exp: u64) -> Natural {
        let mut result = Natural::one();
        let mut base = self.clone();
        while exp > 0 {
            if exp & 1 == 1 {
                result = result.mul(&base);
            }
            exp >>= 1;
            if exp > 0 {
                base = base.mul(&base);
            }
        }
        result
    }
}

impl From<u64> for Natural {
    fn from(mut v: u64) -> Natural {
        let mut limbs = Vec::new();
        while v > 0 {
            limbs.push((v % BASE) as u32);
            v /= BASE;
        }
        Natural { limbs }
    }
}

impl Ord for Natural {
    fn cmp(&self, other: &Natural) -> Ordering {
        self.limbs
            .len()
            .cmp(&other.limbs.len())
            .then_with(|| self.limbs.iter().rev().cmp(other.limbs.iter().rev()))
    }
}

impl PartialOrd for Natural {
    fn partial_cmp(&self, other: &Natural) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl fmt::Display for Natural {
    /// Prints canonical decimal digits, in time linear in the number of digits.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut s = String::with_capacity(self.limbs.len() * LIMB_DIGITS + 1);
        match self.limbs.split_last() {
            None => s.push('0'),
            Some((top, rest)) => {
                s.push_str(&top.to_string());
                for l in rest.iter().rev() {
                    s.push_str(&format!("{l:09}"));
                }
            }
        }
        f.pad_integral(true, "", &s)
    }
}

impl fmt::Debug for Natural {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Natural({self})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(s: &str) -> Natural {
        Natural::from_decimal(s).unwrap()
    }

    #[test]
    fn parse_and_print() {
        assert_eq!(n("0").to_string(), "0");
        assert_eq!(n("000").to_string(), "0");
        assert_eq!(n("0007").to_string(), "7");
        assert_eq!(n("1000000000").to_string(), "1000000000");
        assert_eq!(n("123456789012345678901234567890").to_string(), "123456789012345678901234567890");
        assert!(Natural::from_decimal("").is_err());
        assert!(Natural::from_decimal("12a").is_err());
        assert!(Natural::from_decimal("-1").is_err());
    }

    #[test]
    fn add_sub() {
        assert_eq!(n("999999999").add(&n("1")).to_string(), "1000000000");
        assert_eq!(
            n("1000000000000000000000000000000").checked_sub(&n("1")).unwrap().to_string(),
            "999999999999999999999999999999"
        );
        assert!(n("1").checked_sub(&n("2")).is_none());
        assert!(n("5").checked_sub(&n("5")).unwrap().is_zero());
    }

    #[test]
    fn mul_and_pow() {
        assert_eq!(n("99999999999").mul(&n("99999999999")).to_string(), "9999999999800000000001");
        assert_eq!(n("2").pow(100).to_string(), "1267650600228229401496703205376");
        assert_eq!(n("0").pow(0).to_string(), "1");
        assert_eq!(n("0").pow(5).to_string(), "0");
    }

    #[test]
    fn division_identity() {
        // Includes cases that exercise the qhat correction and add-back paths.
        let cases = [
            ("1000000000000000000000000000", "999999999999999999"),
            ("999999999999999999999999999999999999", "999999999999999999"),
            ("1000000000000000000000000000000000000", "1000000000000000001"),
            ("123456789012345678901234567890123456789", "98765432109876543210"),
            ("340282366920938463463374607431768211455", "18446744073709551616"),
            ("999999999000000000000000000", "999999999000000001"),
        ];
        for (a, b) in cases {
            let (a, b) = (n(a), n(b));
            let (q, r) = a.div_rem(&b).unwrap();
            assert!(r < b);
            assert_eq!(q.mul(&b).add(&r), a);
        }
        assert_eq!(n("5").div_rem(&n("0")), Err(ArithmeticError::DivisionByZero));
    }

    #[test]
    fn to_u64_bounds() {
        assert_eq!(n("18446744073709551615").to_u64(), Some(u64::MAX));
        assert_eq!(n("18446744073709551616").to_u64(), None);
        assert_eq!(n("0").to_u64(), Some(0));
    }
}
