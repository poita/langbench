//! Exact decimal numbers.
//!
//! A JSON number literal denotes the rational `m × 10^e`. [`Number`] stores
//! exactly that pair in canonical form (no trailing zeros in `m`, zero has
//! exponent 0), so structural equality is numeric equality and no binary
//! floating point is ever involved.

use crate::bigint::BigUint;
use std::cmp::Ordering;
use std::fmt;

/// An exact decimal number `±mantissa × 10^exp`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Number {
    neg: bool,
    mag: BigUint,
    exp: i64,
    /// Number of decimal digits in `mag` (0 for the number zero).
    digits: i64,
}

impl Number {
    /// The number zero.
    pub fn zero() -> Self {
        Number {
            neg: false,
            mag: BigUint::zero(),
            exp: 0,
            digits: 0,
        }
    }

    /// Builds a number from a sign, a string of decimal digits (leading and
    /// trailing zeros allowed) and a power of ten.
    ///
    /// Returns `None` if `digits` contains a non-digit.
    pub fn from_parts(neg: bool, digits: &str, exp: i64) -> Option<Self> {
        if !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let trimmed = digits.trim_start_matches('0');
        let stripped = trimmed.trim_end_matches('0');
        if stripped.is_empty() {
            return Some(Number::zero());
        }
        let zeros = (trimmed.len() - stripped.len()) as i64;
        Some(Number {
            neg,
            mag: BigUint::from_decimal(stripped)?,
            exp: exp.saturating_add(zeros),
            digits: stripped.len() as i64,
        })
    }

    /// Parses a JSON number literal: `[-]digits[.digits][(e|E)[+|-]digits]`.
    pub fn parse(text: &str) -> Option<Self> {
        let (neg, rest) = match text.strip_prefix('-') {
            Some(r) => (true, r),
            None => (false, text),
        };
        let (mantissa, exp_part) = match rest.find(['e', 'E']) {
            Some(i) => (&rest[..i], Some(&rest[i + 1..])),
            None => (rest, None),
        };
        let (int_part, frac_part) = match mantissa.split_once('.') {
            Some((i, f)) => (i, f),
            None => (mantissa, ""),
        };
        if int_part.is_empty() || (mantissa.contains('.') && frac_part.is_empty()) {
            return None;
        }
        let mut exp: i64 = match exp_part {
            None => 0,
            Some(e) => {
                let (sign, digits) = match e.as_bytes().first() {
                    Some(b'-') => (-1i64, &e[1..]),
                    Some(b'+') => (1, &e[1..]),
                    _ => (1, e),
                };
                if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                // Saturate absurdly long exponents instead of failing.
                let v = digits
                    .trim_start_matches('0')
                    .parse::<i64>()
                    .unwrap_or(if digits.trim_start_matches('0').is_empty() { 0 } else { i64::MAX / 4 });
                sign * v.min(i64::MAX / 4)
            }
        };
        exp -= frac_part.len() as i64;
        let mut all = String::with_capacity(int_part.len() + frac_part.len());
        all.push_str(int_part);
        all.push_str(frac_part);
        Number::from_parts(neg, &all, exp)
    }

    /// Builds a number from an unsigned integer.
    pub fn from_u64(v: u64) -> Self {
        Number::from_parts(false, &v.to_string(), 0).expect("digits are valid")
    }

    /// Returns `true` for zero (including `-0`).
    pub fn is_zero(&self) -> bool {
        self.mag.is_zero()
    }

    /// Returns `true` if the number denotes a whole number (`1.0`, `1e2` and
    /// `-0` are integers; `1.5` is not).
    pub fn is_integer(&self) -> bool {
        self.is_zero() || self.exp >= 0
    }

    /// Returns `true` if the number is strictly negative.
    pub fn is_negative(&self) -> bool {
        self.neg
    }

    /// Converts to `usize` when the number is a non-negative integer that
    /// fits.
    pub fn to_usize(&self) -> Option<usize> {
        if self.neg || !self.is_integer() {
            return None;
        }
        if self.is_zero() {
            return Some(0);
        }
        if self.exp > 19 {
            return None;
        }
        let mut m = self.mag.clone();
        m.mul_pow10(self.exp as u64);
        m.to_u64().and_then(|v| usize::try_from(v).ok())
    }

    fn cmp_abs(&self, other: &Number) -> Ordering {
        // Order of magnitude first: value is in [10^(adj-1), 10^adj).
        let adj_a = self.exp.saturating_add(self.digits);
        let adj_b = other.exp.saturating_add(other.digits);
        if adj_a != adj_b {
            return adj_a.cmp(&adj_b);
        }
        // Equal magnitude: the exponent gap is bounded by the digit counts.
        if self.exp >= other.exp {
            let mut a = self.mag.clone();
            a.mul_pow10((self.exp - other.exp) as u64);
            a.cmp(&other.mag)
        } else {
            let mut b = other.mag.clone();
            b.mul_pow10((other.exp - self.exp) as u64);
            self.mag.cmp(&b)
        }
    }

    /// Returns `true` if `self / divisor` is an integer, computed exactly.
    /// Zero is a multiple of everything; nothing is a multiple of zero.
    pub fn is_multiple_of(&self, divisor: &Number) -> bool {
        if divisor.is_zero() {
            return false;
        }
        if self.is_zero() {
            return true;
        }
        // self / divisor = (m1 / m2) × 10^(e1 - e2)
        let d = self.exp - divisor.exp;
        if d >= 0 {
            let mut m1 = self.mag.clone();
            m1.mul_pow10(d as u64);
            m1.rem(&divisor.mag).is_zero()
        } else {
            let shift = d.unsigned_abs();
            // m2 × 10^shift exceeds m1 whenever shift ≥ digits(m1).
            if shift as i64 >= self.digits {
                return false;
            }
            let mut m2 = divisor.mag.clone();
            m2.mul_pow10(shift);
            self.mag.rem(&m2).is_zero()
        }
    }
}

impl PartialOrd for Number {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Number {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self.is_zero(), other.is_zero()) {
            (true, true) => return Ordering::Equal,
            (true, false) => {
                return if other.neg { Ordering::Greater } else { Ordering::Less };
            }
            (false, true) => {
                return if self.neg { Ordering::Less } else { Ordering::Greater };
            }
            _ => {}
        }
        if self.neg != other.neg {
            return if self.neg { Ordering::Less } else { Ordering::Greater };
        }
        let o = self.cmp_abs(other);
        if self.neg {
            o.reverse()
        } else {
            o
        }
    }
}

impl fmt::Display for Number {
    /// Formats as `[-]<mantissa>e<exponent>` (or `0`), which round-trips
    /// through [`Number::parse`].
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_zero() {
            return f.write_str("0");
        }
        if self.neg {
            f.write_str("-")?;
        }
        if self.exp == 0 {
            write!(f, "{}", self.mag)
        } else {
            write!(f, "{}e{}", self.mag, self.exp)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(s: &str) -> Number {
        Number::parse(s).unwrap_or_else(|| panic!("bad literal {s}"))
    }

    #[test]
    fn equal_spellings_are_equal() {
        for s in ["1", "1.0", "1.00", "1e0", "10e-1", "0.1e1", "100e-2"] {
            assert_eq!(n(s), n("1"), "{s}");
        }
        assert_eq!(n("100"), n("1e2"));
        assert_eq!(n("-0"), n("0"));
        assert_eq!(n("-0.0"), n("0e5"));
    }

    #[test]
    fn integer_detection() {
        assert!(n("1.0").is_integer());
        assert!(n("1e2").is_integer());
        assert!(n("-0").is_integer());
        assert!(n("0.0").is_integer());
        assert!(!n("1.5").is_integer());
        assert!(!n("1e-1").is_integer());
        assert!(n("12.50e1").is_integer());
    }

    #[test]
    fn ordering() {
        assert!(n("1e309") > n("1e308"));
        assert!(n("-1e309") < n("-1e308"));
        assert!(n("0.1") < n("0.11"));
        assert!(n("-0.1") > n("-0.11"));
        assert!(n("-1") < n("0"));
        assert!(n("0") < n("1e-400"));
        assert!(n("1e400") > n("9999999999999999999999999999999999"));
        assert_eq!(n("2.0").cmp(&n("2")), Ordering::Equal);
        assert!(n("123456789012345678901234567890.5") > n("123456789012345678901234567890.4999"));
    }

    #[test]
    fn multiple_of_is_exact() {
        assert!(n("0.3").is_multiple_of(&n("0.0001")));
        assert!(n("0.0021").is_multiple_of(&n("0.0001")));
        assert!(n("4.5").is_multiple_of(&n("1.5")));
        assert!(!n("4.5").is_multiple_of(&n("2")));
        assert!(n("1e308").is_multiple_of(&n("0.5")));
        assert!(!n("0.00075").is_multiple_of(&n("0.0001")));
        assert!(n("0").is_multiple_of(&n("7")));
        assert!(n("-9").is_multiple_of(&n("3")));
        assert!(!n("7").is_multiple_of(&n("1e400")));
        assert!(!n("1e-400").is_multiple_of(&n("3")));
    }

    #[test]
    fn to_usize() {
        assert_eq!(n("2.0").to_usize(), Some(2));
        assert_eq!(n("2e0").to_usize(), Some(2));
        assert_eq!(n("1e2").to_usize(), Some(100));
        assert_eq!(n("-1").to_usize(), None);
        assert_eq!(n("1.5").to_usize(), None);
        assert_eq!(n("1e400").to_usize(), None);
    }

    #[test]
    fn rejects_malformed() {
        for s in ["", "-", "1.", ".5", "1e", "1e+", "a"] {
            assert!(Number::parse(s).is_none(), "{s}");
        }
    }

    #[test]
    fn display_round_trips() {
        for s in ["0", "1", "-12", "1.5", "1e400", "-3.25e-7"] {
            assert_eq!(Number::parse(&n(s).to_string()).unwrap(), n(s));
        }
    }
}
