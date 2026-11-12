//! Unsigned arbitrary-precision integers.
//!
//! A [`Natural`] is a little-endian vector of base 10⁹ limbs with no
//! most-significant zero limbs; zero is the empty vector. Because the limb
//! base is a power of ten, converting from and to decimal text is linear.

use crate::error::ParseError;
use std::cmp::Ordering;
use std::fmt;

/// The limb base, 10⁹.
const BASE: u64 = 1_000_000_000;
/// Decimal digits per limb.
const LIMB_DIGITS: usize = 9;

/// An unsigned arbitrary-precision integer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Natural {
    /// Little-endian limbs, each `< BASE`, last limb non-zero.
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

    /// Returns `true` if the value is odd.
    pub fn is_odd(&self) -> bool {
        // BASE is even, so parity is the parity of the lowest limb.
        self.limbs.first().is_some_and(|l| l & 1 == 1)
    }

    /// Converts to `u64` if the value fits.
    pub fn to_u64(&self) -> Option<u64> {
        let mut acc: u64 = 0;
        for &l in self.limbs.iter().rev() {
            acc = acc.checked_mul(BASE)?.checked_add(l as u64)?;
        }
        Some(acc)
    }

    /// Parses a string of ASCII digits (leading zeros allowed).
    pub fn from_decimal(s: &str) -> Result<Natural, ParseError> {
        let bytes = s.as_bytes();
        if bytes.is_empty() {
            return Err(ParseError::Empty);
        }
        if !bytes.iter().all(u8::is_ascii_digit) {
            return Err(ParseError::InvalidDigit);
        }
        let start = bytes.iter().position(|&b| b != b'0').unwrap_or(bytes.len());
        let digits = &bytes[start..];
        let mut limbs = Vec::with_capacity(digits.len() / LIMB_DIGITS + 1);
        let mut end = digits.len();
        while end > 0 {
            let begin = end.saturating_sub(LIMB_DIGITS);
            let limb = digits[begin..end]
                .iter()
                .fold(0u32, |acc, &d| acc * 10 + (d - b'0') as u32);
            limbs.push(limb);
            end = begin;
        }
        Ok(Natural { limbs })
    }

    fn from_limbs(mut limbs: Vec<u32>) -> Natural {
        while limbs.last() == Some(&0) {
            limbs.pop();
        }
        Natural { limbs }
    }

    /// Adds two values, O(n + m).
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
            if s as u64 >= BASE {
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

    /// Subtracts `other` from `self`, O(n + m).
    ///
    /// # Panics
    ///
    /// Panics if `other > self`.
    pub fn sub(&self, other: &Natural) -> Natural {
        assert!(
            self >= other,
            "Natural subtraction would produce a negative result"
        );
        let mut out = Vec::with_capacity(self.limbs.len());
        let mut borrow = 0i64;
        for (i, &l) in self.limbs.iter().enumerate() {
            let mut d = l as i64 - borrow - other.limbs.get(i).copied().unwrap_or(0) as i64;
            if d < 0 {
                d += BASE as i64;
                borrow = 1;
            } else {
                borrow = 0;
            }
            out.push(d as u32);
        }
        Natural::from_limbs(out)
    }

    /// Multiplies two values with schoolbook long multiplication, O(n·m).
    pub fn mul(&self, other: &Natural) -> Natural {
        if self.is_zero() || other.is_zero() {
            return Natural::zero();
        }
        let (a, b) = if self.limbs.len() >= other.limbs.len() {
            (&self.limbs, &other.limbs)
        } else {
            (&other.limbs, &self.limbs)
        };
        let mut out = vec![0u32; a.len() + b.len()];
        for (i, &bi) in b.iter().enumerate() {
            if bi == 0 {
                continue;
            }
            let bi = bi as u64;
            let mut carry = 0u64;
            let row = &mut out[i..i + a.len() + 1];
            for (slot, &aj) in row.iter_mut().zip(a.iter()) {
                // slot < BASE, aj*bi <= (BASE-1)^2, carry < BASE: fits in u64.
                let cur = *slot as u64 + aj as u64 * bi + carry;
                carry = cur / BASE;
                *slot = (cur % BASE) as u32;
            }
            // The slot above this row's span has not been written by row i
            // before, so it is zero and `carry < BASE` fits.
            row[a.len()] = carry as u32;
        }
        Natural::from_limbs(out)
    }

    /// Divides by a single limb value `d` (`0 < d < 10⁹`), returning
    /// `(quotient, remainder)`.
    fn div_rem_small(&self, d: u32) -> (Natural, u32) {
        debug_assert!(d != 0 && (d as u64) < BASE);
        let d = d as u64;
        let mut q = vec![0u32; self.limbs.len()];
        let mut rem = 0u64;
        for i in (0..self.limbs.len()).rev() {
            let cur = rem * BASE + self.limbs[i] as u64;
            q[i] = (cur / d) as u32;
            rem = cur % d;
        }
        (Natural::from_limbs(q), rem as u32)
    }

    /// Multiplies every limb by `m < BASE`, returning `len + 1` limbs.
    fn mul_small_padded(limbs: &[u32], m: u64) -> Vec<u32> {
        let mut out = Vec::with_capacity(limbs.len() + 1);
        let mut carry = 0u64;
        for &l in limbs {
            let cur = l as u64 * m + carry;
            out.push((cur % BASE) as u32);
            carry = cur / BASE;
        }
        out.push(carry as u32);
        out
    }

    /// Divides `self` by `divisor`, returning `(quotient, remainder)`.
    ///
    /// Uses Knuth's Algorithm D (TAOCP vol. 2, §4.3.1): each quotient limb is
    /// estimated from the leading limbs and corrected at most twice, giving
    /// O((n − m + 1)·m) overall.
    ///
    /// # Panics
    ///
    /// Panics if `divisor` is zero.
    pub fn div_rem(&self, divisor: &Natural) -> (Natural, Natural) {
        assert!(!divisor.is_zero(), "division by zero");
        if self < divisor {
            return (Natural::zero(), self.clone());
        }
        if divisor.limbs.len() == 1 {
            let (q, r) = self.div_rem_small(divisor.limbs[0]);
            return (q, Natural::from(r as u64));
        }

        let n = divisor.limbs.len();
        let m = self.limbs.len() - n;
        // D1: normalise so the divisor's top limb is >= BASE/2.
        let d = BASE / (divisor.limbs[n - 1] as u64 + 1);
        let mut u = Natural::mul_small_padded(&self.limbs, d); // m + n + 1 limbs
        let v = Natural::mul_small_padded(&divisor.limbs, d); // n + 1 limbs, top is 0
        let v = &v[..n];
        let (v1, v2) = (v[n - 1] as u64, v[n - 2] as u64);
        let mut q = vec![0u32; m + 1];

        for j in (0..=m).rev() {
            // D3: estimate the quotient limb.
            let top = u[j + n] as u64 * BASE + u[j + n - 1] as u64;
            let mut qhat = top / v1;
            let mut rhat = top % v1;
            while qhat >= BASE || qhat * v2 > rhat * BASE + u[j + n - 2] as u64 {
                qhat -= 1;
                rhat += v1;
                if rhat >= BASE {
                    break;
                }
            }

            // D4: multiply and subtract qhat * v from u[j..=j+n].
            let mut borrow = 0i64;
            let mut carry = 0u64;
            for i in 0..n {
                let p = qhat * v[i] as u64 + carry;
                carry = p / BASE;
                let mut t = u[i + j] as i64 - borrow - (p % BASE) as i64;
                if t < 0 {
                    t += BASE as i64;
                    borrow = 1;
                } else {
                    borrow = 0;
                }
                u[i + j] = t as u32;
            }
            let mut t = u[j + n] as i64 - borrow - carry as i64;
            let negative = t < 0;
            if negative {
                t += BASE as i64;
            }
            u[j + n] = t as u32;

            // D5/D6: if the subtraction went negative, add the divisor back.
            if negative {
                qhat -= 1;
                let mut c = 0u32;
                for i in 0..n {
                    let mut s = u[i + j] + v[i] + c;
                    if s as u64 >= BASE {
                        s -= BASE as u32;
                        c = 1;
                    } else {
                        c = 0;
                    }
                    u[i + j] = s;
                }
                u[j + n] = ((u[j + n] as u64 + c as u64) % BASE) as u32;
            }
            q[j] = qhat as u32;
        }

        // D8: un-normalise the remainder.
        u.truncate(n);
        let (r, rem) = Natural::from_limbs(u).div_rem_small(d as u32);
        debug_assert_eq!(rem, 0);
        (Natural::from_limbs(q), r)
    }

    /// Raises `self` to the power `exp` by binary exponentiation,
    /// O(log exp) multiplications.
    pub fn pow(&self, mut exp: u64) -> Natural {
        let mut result = Natural::one();
        if exp == 0 {
            return result;
        }
        let mut base = self.clone();
        loop {
            if exp & 1 == 1 {
                result = result.mul(&base);
            }
            exp >>= 1;
            if exp == 0 {
                return result;
            }
            base = base.mul(&base);
        }
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

impl PartialOrd for Natural {
    fn partial_cmp(&self, other: &Natural) -> Option<Ordering> {
        Some(self.cmp(other))
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

impl fmt::Display for Natural {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut s = String::with_capacity(self.limbs.len() * LIMB_DIGITS + 1);
        match self.limbs.split_last() {
            None => s.push('0'),
            Some((top, rest)) => {
                s.push_str(&top.to_string());
                for l in rest.iter().rev() {
                    s.push_str(&format!("{:09}", l));
                }
            }
        }
        f.pad_integral(true, "", &s)
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
        assert_eq!(Natural::from_decimal(""), Err(ParseError::Empty));
        assert_eq!(Natural::from_decimal("1x"), Err(ParseError::InvalidDigit));
        assert_eq!(Natural::from_decimal("-1"), Err(ParseError::InvalidDigit));
    }

    #[test]
    fn add_sub_carry_chains() {
        let a = n("999999999999999999999999999");
        assert_eq!(a.add(&Natural::one()).to_string(), "1000000000000000000000000000");
        assert_eq!(a.add(&Natural::one()).sub(&Natural::one()), a);
        assert!(a.sub(&a).is_zero());
    }

    #[test]
    #[should_panic]
    fn sub_underflow_panics() {
        let _ = n("1").sub(&n("2"));
    }

    #[test]
    fn mul_basic() {
        assert_eq!(n("999999999").mul(&n("999999999")).to_string(), "999999998000000001");
        assert!(n("0").mul(&n("12345678901234567890")).is_zero());
        assert_eq!(
            n("99999999999999999999999999").mul(&n("99999999999999999999999999")).to_string(),
            "9999999999999999999999999800000000000000000000000001"
        );
    }

    #[test]
    fn div_rem_matches_identity() {
        let a = n("123456789012345678901234567890123456789012345678901234567890");
        let b = n("98765432109876543210987654321");
        let (q, r) = a.div_rem(&b);
        assert!(r < b);
        assert_eq!(q.mul(&b).add(&r), a);
    }

    #[test]
    fn div_rem_add_back_case() {
        // Divisors/dividends with limbs at the extremes exercise the
        // qhat correction and add-back paths.
        let b = n("999999999999999999999999999");
        let a = b.mul(&n("999999999999999999")).add(&b.sub(&Natural::one()));
        let (q, r) = a.div_rem(&b);
        assert_eq!(q.to_string(), "999999999999999999");
        assert_eq!(r, b.sub(&Natural::one()));
    }

    #[test]
    fn pow_and_to_u64() {
        assert_eq!(n("2").pow(100).to_string(), "1267650600228229401496703205376");
        assert_eq!(n("0").pow(0).to_string(), "1");
        assert_eq!(n("18446744073709551615").to_u64(), Some(u64::MAX));
        assert_eq!(n("18446744073709551616").to_u64(), None);
    }

    #[test]
    fn ordering() {
        assert!(n("10") > n("9"));
        assert!(n("1000000000") > n("999999999"));
        assert_eq!(n("007").cmp(&n("7")), Ordering::Equal);
    }
}
