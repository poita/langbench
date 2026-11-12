//! A minimal arbitrary-precision unsigned integer.
//!
//! Only the handful of operations needed for exact decimal arithmetic on JSON
//! numbers are provided: construction from decimal digits, multiplication by
//! small factors and powers of ten, comparison and remainder.

use std::cmp::Ordering;

/// An arbitrary-precision unsigned integer (little-endian base-2³² limbs).
///
/// The representation is canonical: there are never trailing zero limbs, so
/// the derived `Eq` and `Hash` are consistent with numeric equality.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Default)]
pub struct BigUint {
    limbs: Vec<u32>,
}

impl BigUint {
    /// The value zero.
    pub fn zero() -> Self {
        BigUint { limbs: Vec::new() }
    }

    /// Builds a value from a `u64`.
    pub fn from_u64(v: u64) -> Self {
        let mut b = BigUint {
            limbs: vec![v as u32, (v >> 32) as u32],
        };
        b.trim();
        b
    }

    /// Parses a string of ASCII decimal digits. Returns `None` if the string
    /// is empty or contains anything else.
    pub fn from_decimal(digits: &str) -> Option<Self> {
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let mut n = BigUint::zero();
        let bytes = digits.as_bytes();
        // Consume in chunks of up to nine digits (10^9 < 2^32).
        let first = match bytes.len() % 9 {
            0 => 9,
            r => r,
        };
        let mut pos = 0;
        let mut len = first;
        while pos < bytes.len() {
            let mut chunk = 0u32;
            let mut scale = 1u32;
            for &b in &bytes[pos..pos + len] {
                chunk = chunk * 10 + u32::from(b - b'0');
                scale *= 10;
            }
            n.mul_small(scale);
            n.add_small(chunk);
            pos += len;
            len = 9;
        }
        Some(n)
    }

    /// Returns `true` if the value is zero.
    pub fn is_zero(&self) -> bool {
        self.limbs.is_empty()
    }

    /// Converts to `u64` if the value fits.
    pub fn to_u64(&self) -> Option<u64> {
        match self.limbs.len() {
            0 => Some(0),
            1 => Some(u64::from(self.limbs[0])),
            2 => Some(u64::from(self.limbs[0]) | (u64::from(self.limbs[1]) << 32)),
            _ => None,
        }
    }

    fn trim(&mut self) {
        while self.limbs.last() == Some(&0) {
            self.limbs.pop();
        }
    }

    /// Multiplies in place by a small factor.
    pub fn mul_small(&mut self, m: u32) {
        if m == 0 {
            self.limbs.clear();
            return;
        }
        let mut carry = 0u64;
        for limb in &mut self.limbs {
            let v = u64::from(*limb) * u64::from(m) + carry;
            *limb = v as u32;
            carry = v >> 32;
        }
        if carry > 0 {
            self.limbs.push(carry as u32);
        }
    }

    /// Adds a small value in place.
    pub fn add_small(&mut self, a: u32) {
        let mut carry = u64::from(a);
        for limb in &mut self.limbs {
            if carry == 0 {
                return;
            }
            let v = u64::from(*limb) + carry;
            *limb = v as u32;
            carry = v >> 32;
        }
        if carry > 0 {
            self.limbs.push(carry as u32);
        }
    }

    /// Multiplies in place by `10^k`.
    pub fn mul_pow10(&mut self, mut k: u64) {
        if self.is_zero() {
            return;
        }
        while k >= 9 {
            self.mul_small(1_000_000_000);
            k -= 9;
        }
        if k > 0 {
            self.mul_small(10u32.pow(k as u32));
        }
    }

    /// Divides in place by a small non-zero divisor, returning the remainder.
    pub fn div_rem_small(&mut self, d: u32) -> u32 {
        debug_assert!(d != 0);
        let mut rem = 0u64;
        for limb in self.limbs.iter_mut().rev() {
            let cur = (rem << 32) | u64::from(*limb);
            *limb = (cur / u64::from(d)) as u32;
            rem = cur % u64::from(d);
        }
        self.trim();
        rem as u32
    }

    fn rem_small(&self, d: u32) -> u32 {
        let mut rem = 0u64;
        for &limb in self.limbs.iter().rev() {
            rem = ((rem << 32) | u64::from(limb)) % u64::from(d);
        }
        rem as u32
    }

    fn bit_len(&self) -> usize {
        match self.limbs.last() {
            None => 0,
            Some(&top) => self.limbs.len() * 32 - top.leading_zeros() as usize,
        }
    }

    fn bit(&self, i: usize) -> bool {
        (self.limbs[i / 32] >> (i % 32)) & 1 == 1
    }

    fn shl1_or(&mut self, bit: bool) {
        let mut carry = u32::from(bit);
        for limb in &mut self.limbs {
            let next = *limb >> 31;
            *limb = (*limb << 1) | carry;
            carry = next;
        }
        if carry > 0 {
            self.limbs.push(carry);
        }
    }

    fn sub_assign(&mut self, other: &BigUint) {
        debug_assert!(*self >= *other);
        let mut borrow = 0i64;
        for i in 0..self.limbs.len() {
            let o = i64::from(other.limbs.get(i).copied().unwrap_or(0));
            let mut v = i64::from(self.limbs[i]) - o - borrow;
            if v < 0 {
                v += 1 << 32;
                borrow = 1;
            } else {
                borrow = 0;
            }
            self.limbs[i] = v as u32;
        }
        self.trim();
    }

    /// Returns `self mod d`. Panics if `d` is zero.
    pub fn rem(&self, d: &BigUint) -> BigUint {
        assert!(!d.is_zero(), "division by zero");
        if self < d {
            return self.clone();
        }
        if d.limbs.len() == 1 {
            return BigUint::from_u64(u64::from(self.rem_small(d.limbs[0])));
        }
        // Binary long division; only the remainder is kept.
        let mut r = BigUint::zero();
        for i in (0..self.bit_len()).rev() {
            r.shl1_or(self.bit(i));
            r.trim();
            if r >= *d {
                r.sub_assign(d);
            }
        }
        r
    }
}

impl PartialOrd for BigUint {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for BigUint {
    fn cmp(&self, other: &Self) -> Ordering {
        self.limbs
            .len()
            .cmp(&other.limbs.len())
            .then_with(|| self.limbs.iter().rev().cmp(other.limbs.iter().rev()))
    }
}

impl std::fmt::Display for BigUint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.is_zero() {
            return f.write_str("0");
        }
        let mut n = self.clone();
        let mut parts = Vec::new();
        while !n.is_zero() {
            parts.push(n.div_rem_small(1_000_000_000));
        }
        let mut s = parts.pop().unwrap().to_string();
        for p in parts.iter().rev() {
            s.push_str(&format!("{p:09}"));
        }
        f.write_str(&s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn big(s: &str) -> BigUint {
        BigUint::from_decimal(s).unwrap()
    }

    #[test]
    fn decimal_round_trip() {
        for s in ["0", "7", "4294967296", "123456789012345678901234567890"] {
            assert_eq!(big(s).to_string(), s);
        }
        assert_eq!(big("000123").to_string(), "123");
    }

    #[test]
    fn rejects_non_digits() {
        assert!(BigUint::from_decimal("").is_none());
        assert!(BigUint::from_decimal("12a").is_none());
    }

    #[test]
    fn pow10_and_compare() {
        let mut a = big("3");
        a.mul_pow10(30);
        assert_eq!(a.to_string(), format!("3{}", "0".repeat(30)));
        assert!(a > big("2999999999999999999999999999999"));
        assert!(a < big("3000000000000000000000000000001"));
    }

    #[test]
    fn remainder() {
        assert_eq!(big("100").rem(&big("7")), big("2"));
        let mut a = big("1");
        a.mul_pow10(60);
        let mut d = big("25");
        d.mul_pow10(40);
        assert!(a.rem(&d).is_zero());
        d.add_small(1);
        assert!(!a.rem(&d).is_zero());
        assert_eq!(big("5").rem(&big("9")), big("5"));
    }

    #[test]
    fn big_remainder_matches_native() {
        let a: u128 = 340282366920938463463374607431768211455;
        let d: u128 = 18446744073709551629;
        assert_eq!(
            big(&a.to_string()).rem(&big(&d.to_string())).to_string(),
            (a % d).to_string()
        );
    }
}
