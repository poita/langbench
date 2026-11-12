//! Signed arbitrary-precision integers.

use std::cmp::Ordering;
use std::fmt;
use std::ops::{Add, Mul, Neg, Sub};
use std::str::FromStr;

use crate::error::{ArithmeticError, ParseError};
use crate::natural::Natural;

/// A signed integer of arbitrary size, stored as sign and magnitude.
///
/// Zero is never negative, so there is no "negative zero" value.
#[derive(Clone, Default, PartialEq, Eq, Hash)]
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

    /// Returns `true` if the value is strictly less than zero.
    pub fn is_negative(&self) -> bool {
        self.negative
    }

    /// The absolute value as a [`Natural`].
    pub fn magnitude(&self) -> &Natural {
        &self.magnitude
    }

    /// Truncating division: returns `(quotient, remainder)` with the quotient
    /// rounded toward zero and the remainder taking the sign of `self`, so that
    /// `self == q * divisor + r`.
    pub fn div_rem(&self, divisor: &BigInt) -> Result<(BigInt, BigInt), ArithmeticError> {
        let (q, r) = self.magnitude.div_rem(&divisor.magnitude)?;
        Ok((
            BigInt::new(self.negative != divisor.negative, q),
            BigInt::new(self.negative, r),
        ))
    }

    /// Truncating quotient.
    pub fn div(&self, divisor: &BigInt) -> Result<BigInt, ArithmeticError> {
        self.div_rem(divisor).map(|(q, _)| q)
    }

    /// Remainder with the sign of `self`.
    pub fn rem(&self, divisor: &BigInt) -> Result<BigInt, ArithmeticError> {
        self.div_rem(divisor).map(|(_, r)| r)
    }

    /// Raises `self` to the power `exp` by binary exponentiation.
    ///
    /// `x^0 == 1` for every `x`, including zero. A negative exponent yields
    /// [`ArithmeticError::NegativeExponent`]. An exponent that does not fit in
    /// a `u64` is only accepted for the bases 0, 1 and −1, whose powers are
    /// trivial; otherwise it yields [`ArithmeticError::ExponentTooLarge`].
    pub fn pow(&self, exp: &BigInt) -> Result<BigInt, ArithmeticError> {
        if exp.negative {
            return Err(ArithmeticError::NegativeExponent);
        }
        if exp.is_zero() {
            return Ok(BigInt::one());
        }
        let odd = exp.magnitude.is_odd();
        if self.is_zero() {
            return Ok(BigInt::zero());
        }
        if *self.magnitude() == Natural::one() {
            return Ok(BigInt::new(self.negative && odd, Natural::one()));
        }
        let e = exp.magnitude.to_u64().ok_or(ArithmeticError::ExponentTooLarge)?;
        Ok(BigInt::new(self.negative && odd, self.magnitude.pow(e)))
    }

    /// Adds magnitudes with signs; shared by `+` and `-`.
    fn add_signed(&self, other_negative: bool, other: &Natural) -> BigInt {
        if self.negative == other_negative {
            return BigInt::new(self.negative, self.magnitude.add(other));
        }
        match self.magnitude.cmp(other) {
            Ordering::Equal => BigInt::zero(),
            Ordering::Greater => {
                BigInt::new(self.negative, self.magnitude.checked_sub(other).unwrap())
            }
            Ordering::Less => BigInt::new(
                other_negative,
                other.checked_sub(&self.magnitude).unwrap(),
            ),
        }
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
        let digits = self.magnitude.to_string();
        f.pad_integral(!self.negative, "", &digits)
    }
}

impl fmt::Debug for BigInt {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "BigInt({self})")
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

impl PartialOrd for BigInt {
    fn partial_cmp(&self, other: &BigInt) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Neg for BigInt {
    type Output = BigInt;
    fn neg(self) -> BigInt {
        BigInt::new(!self.negative, self.magnitude)
    }
}

impl<'a> Add<&'a BigInt> for &'a BigInt {
    type Output = BigInt;
    fn add(self, rhs: &BigInt) -> BigInt {
        self.add_signed(rhs.negative, &rhs.magnitude)
    }
}

impl<'a> Sub<&'a BigInt> for &'a BigInt {
    type Output = BigInt;
    fn sub(self, rhs: &BigInt) -> BigInt {
        self.add_signed(!rhs.negative, &rhs.magnitude)
    }
}

impl<'a> Mul<&'a BigInt> for &'a BigInt {
    type Output = BigInt;
    fn mul(self, rhs: &BigInt) -> BigInt {
        BigInt::new(self.negative != rhs.negative, self.magnitude.mul(&rhs.magnitude))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(s: &str) -> BigInt {
        s.parse().unwrap()
    }

    #[test]
    fn zero_forms() {
        assert_eq!(b("-0").to_string(), "0");
        assert_eq!(b("-000"), b("0"));
        assert!(!b("-0").is_negative());
        assert_eq!(b("-007").to_string(), "-7");
        assert!("".parse::<BigInt>().is_err());
        assert!("-".parse::<BigInt>().is_err());
        assert!("+1".parse::<BigInt>().is_err());
    }

    #[test]
    fn signed_add_sub() {
        assert_eq!((&b("5") - &b("7")).to_string(), "-2");
        assert_eq!((&b("-5") + &b("5")).to_string(), "0");
        assert_eq!((&b("-5") - &b("-7")).to_string(), "2");
        assert_eq!((&b("-0") + &b("0")).to_string(), "0");
    }

    #[test]
    fn signed_division_table() {
        let cases = [
            (7, 2, 3, 1),
            (-7, 2, -3, -1),
            (7, -2, -3, 1),
            (-7, -2, 3, -1),
            (-1, 3, 0, -1),
            (-7, 7, -1, 0),
            (-1, 2, 0, -1),
        ];
        for (a, d, q, r) in cases {
            let (gq, gr) = BigInt::from(a).div_rem(&BigInt::from(d)).unwrap();
            assert_eq!((gq, gr), (BigInt::from(q), BigInt::from(r)), "{a} / {d}");
        }
        assert_eq!(b("0").div_rem(&b("-0")), Err(ArithmeticError::DivisionByZero));
    }

    #[test]
    fn power() {
        assert_eq!(b("-2").pow(&b("3")).unwrap().to_string(), "-8");
        assert_eq!(b("-2").pow(&b("2")).unwrap().to_string(), "4");
        assert_eq!(b("0").pow(&b("0")).unwrap().to_string(), "1");
        assert_eq!(b("0").pow(&b("-0")).unwrap().to_string(), "1");
        assert_eq!(b("-1").pow(&b("999")).unwrap().to_string(), "-1");
        assert_eq!(b("0").pow(&b("5")).unwrap().to_string(), "0");
        assert_eq!(b("5").pow(&b("-1")), Err(ArithmeticError::NegativeExponent));
        assert_eq!(
            b("-1").pow(&b("100000000000000000000000000001")).unwrap().to_string(),
            "-1"
        );
        assert_eq!(
            b("2").pow(&b("100000000000000000000000000000")),
            Err(ArithmeticError::ExponentTooLarge)
        );
    }

    #[test]
    fn ordering() {
        assert!(b("-3") < b("-2"));
        assert!(b("-2") < b("0"));
        assert_eq!(b("007").cmp(&b("7")), Ordering::Equal);
        assert_eq!(b("-0").cmp(&b("0")), Ordering::Equal);
        assert!(b("10") > b("9"));
    }
}
