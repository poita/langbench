//! Signed arbitrary-precision integers.

use crate::error::{ArithmeticError, ParseError};
use crate::natural::Natural;
use std::cmp::Ordering;
use std::fmt;
use std::ops::{Add, Mul, Neg, Sub};
use std::str::FromStr;

/// A signed arbitrary-precision integer (sign and magnitude).
///
/// Zero is always non-negative, so there is no "negative zero" value and
/// equality, ordering and printing are all canonical.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct BigInt {
    negative: bool,
    magnitude: Natural,
}

impl BigInt {
    fn new(negative: bool, magnitude: Natural) -> BigInt {
        BigInt {
            negative: negative && !magnitude.is_zero(),
            magnitude,
        }
    }

    /// The value zero.
    pub fn zero() -> BigInt {
        BigInt::default()
    }

    /// The value one.
    pub fn one() -> BigInt {
        BigInt::from(1)
    }

    /// Returns `true` if the value is zero.
    pub fn is_zero(&self) -> bool {
        self.magnitude.is_zero()
    }

    /// Returns `true` if the value is strictly negative.
    pub fn is_negative(&self) -> bool {
        self.negative
    }

    /// The absolute value.
    pub fn abs(&self) -> BigInt {
        BigInt::new(false, self.magnitude.clone())
    }

    /// Truncating division: returns `(quotient, remainder)` where the
    /// quotient is rounded toward zero and the remainder has the sign of
    /// `self` (C semantics), so `self == q * divisor + r`.
    pub fn div_rem(&self, divisor: &BigInt) -> Result<(BigInt, BigInt), ArithmeticError> {
        if divisor.is_zero() {
            return Err(ArithmeticError::DivisionByZero);
        }
        let (q, r) = self.magnitude.div_rem(&divisor.magnitude);
        Ok((
            BigInt::new(self.negative != divisor.negative, q),
            BigInt::new(self.negative, r),
        ))
    }

    /// Truncating quotient; see [`BigInt::div_rem`].
    pub fn checked_div(&self, divisor: &BigInt) -> Result<BigInt, ArithmeticError> {
        self.div_rem(divisor).map(|(q, _)| q)
    }

    /// Remainder with the sign of `self`; see [`BigInt::div_rem`].
    pub fn checked_rem(&self, divisor: &BigInt) -> Result<BigInt, ArithmeticError> {
        self.div_rem(divisor).map(|(_, r)| r)
    }

    /// Raises `self` to a machine-word power. `x.pow(0)` is `1` for every
    /// `x`, including zero.
    pub fn pow(&self, exp: u64) -> BigInt {
        BigInt::new(self.negative && exp % 2 == 1, self.magnitude.pow(exp))
    }

    /// Raises `self` to a big-integer power.
    ///
    /// Fails with [`ArithmeticError::NegativeExponent`] if `exp < 0`. An
    /// exponent that does not fit in a `u64` is only accepted when the base
    /// is `0`, `1` or `-1` (the only bases whose result stays small);
    /// otherwise [`ArithmeticError::ExponentTooLarge`] is returned.
    pub fn checked_pow(&self, exp: &BigInt) -> Result<BigInt, ArithmeticError> {
        if exp.is_negative() {
            return Err(ArithmeticError::NegativeExponent);
        }
        if let Some(e) = exp.magnitude.to_u64() {
            return Ok(self.pow(e));
        }
        let small_base = self.magnitude.is_zero() || self.magnitude == Natural::one();
        if !small_base {
            return Err(ArithmeticError::ExponentTooLarge);
        }
        // exp > 0 here: 0^exp = 0, 1^exp = 1, (-1)^exp by parity.
        Ok(BigInt::new(self.negative && exp.magnitude.is_odd(), self.magnitude.clone()))
    }
}

impl From<i64> for BigInt {
    fn from(v: i64) -> BigInt {
        BigInt::new(v < 0, Natural::from(v.unsigned_abs()))
    }
}

impl FromStr for BigInt {
    type Err = ParseError;

    /// Parses `-?[0-9]+`. Leading zeros and `-0` are accepted.
    fn from_str(s: &str) -> Result<BigInt, ParseError> {
        let (negative, digits) = match s.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, s),
        };
        Ok(BigInt::new(negative, Natural::from_decimal(digits)?))
    }
}

impl fmt::Display for BigInt {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = self.magnitude.to_string();
        f.pad_integral(!self.negative, "", &s)
    }
}

impl PartialOrd for BigInt {
    fn partial_cmp(&self, other: &BigInt) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for BigInt {
    fn cmp(&self, other: &BigInt) -> Ordering {
        match (self.negative, other.negative) {
            (false, true) => Ordering::Greater,
            (true, false) => Ordering::Less,
            (false, false) => self.magnitude.cmp(&other.magnitude),
            (true, true) => other.magnitude.cmp(&self.magnitude),
        }
    }
}

impl Neg for &BigInt {
    type Output = BigInt;
    fn neg(self) -> BigInt {
        BigInt::new(!self.negative, self.magnitude.clone())
    }
}

impl Neg for BigInt {
    type Output = BigInt;
    fn neg(self) -> BigInt {
        -&self
    }
}

impl Add for &BigInt {
    type Output = BigInt;
    fn add(self, rhs: &BigInt) -> BigInt {
        if self.negative == rhs.negative {
            return BigInt::new(self.negative, self.magnitude.add(&rhs.magnitude));
        }
        match self.magnitude.cmp(&rhs.magnitude) {
            Ordering::Equal => BigInt::zero(),
            Ordering::Greater => BigInt::new(self.negative, self.magnitude.sub(&rhs.magnitude)),
            Ordering::Less => BigInt::new(rhs.negative, rhs.magnitude.sub(&self.magnitude)),
        }
    }
}

impl Sub for &BigInt {
    type Output = BigInt;
    fn sub(self, rhs: &BigInt) -> BigInt {
        self + &(-rhs)
    }
}

impl Mul for &BigInt {
    type Output = BigInt;
    fn mul(self, rhs: &BigInt) -> BigInt {
        BigInt::new(
            self.negative != rhs.negative,
            self.magnitude.mul(&rhs.magnitude),
        )
    }
}

macro_rules! forward_owned {
    ($($tr:ident $m:ident),*) => {$(
        impl $tr for BigInt {
            type Output = BigInt;
            fn $m(self, rhs: BigInt) -> BigInt { $tr::$m(&self, &rhs) }
        }
    )*};
}
forward_owned!(Add add, Sub sub, Mul mul);

#[cfg(test)]
mod tests {
    use super::*;

    fn b(s: &str) -> BigInt {
        s.parse().unwrap()
    }

    #[test]
    fn zero_forms() {
        assert_eq!(b("-0"), BigInt::zero());
        assert_eq!(b("-000").to_string(), "0");
        assert_eq!(b("-0007").to_string(), "-7");
        assert_eq!((&b("-5") * &b("0")).to_string(), "0");
    }

    #[test]
    fn signed_add_sub() {
        assert_eq!((&b("5") - &b("7")).to_string(), "-2");
        assert_eq!((&b("-5") + &b("5")).to_string(), "0");
        assert_eq!((&b("-5") - &b("-7")).to_string(), "2");
    }

    #[test]
    fn div_rem_signs() {
        for (a, d, q, r) in [
            (7, 2, 3, 1),
            (-7, 2, -3, -1),
            (7, -2, -3, 1),
            (-7, -2, 3, -1),
            (-1, 3, 0, -1),
            (-7, 7, -1, 0),
        ] {
            let (gq, gr) = BigInt::from(a).div_rem(&BigInt::from(d)).unwrap();
            assert_eq!((gq, gr), (BigInt::from(q), BigInt::from(r)), "{a} / {d}");
        }
        assert_eq!(
            BigInt::from(1).div_rem(&BigInt::zero()),
            Err(ArithmeticError::DivisionByZero)
        );
    }

    #[test]
    fn pow_rules() {
        assert_eq!(b("0").checked_pow(&b("0")).unwrap().to_string(), "1");
        assert_eq!(b("-2").checked_pow(&b("3")).unwrap().to_string(), "-8");
        assert_eq!(b("-2").checked_pow(&b("2")).unwrap().to_string(), "4");
        assert_eq!(b("5").checked_pow(&b("-0")).unwrap().to_string(), "1");
        assert_eq!(b("2").checked_pow(&b("-1")), Err(ArithmeticError::NegativeExponent));
        assert_eq!(b("-1").checked_pow(&b("99999999999999999999999999999")).unwrap().to_string(), "-1");
        assert_eq!(b("2").checked_pow(&b("99999999999999999999999999999")), Err(ArithmeticError::ExponentTooLarge));
    }

    #[test]
    fn ordering() {
        assert!(b("-3") < b("-2"));
        assert!(b("-1") < b("0"));
        assert_eq!(b("-0").cmp(&b("0")), Ordering::Equal);
        assert!(b("-100") < b("-99"));
    }
}
