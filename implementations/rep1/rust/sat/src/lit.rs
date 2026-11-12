//! Variables and literals.

use std::fmt;
use std::ops::Not;

/// A propositional variable, numbered from 0 internally.
///
/// DIMACS variable `k` (1-based) corresponds to `Var(k - 1)`.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Var(pub u32);

impl Var {
    /// The variable's index, for use in per-variable arrays.
    #[inline]
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

/// A literal: a variable or its negation.
///
/// Encoded as `2 * var + sign` where `sign == 1` means negated, so that
/// literals can index watch lists directly.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Lit(u32);

impl Lit {
    /// The literal asserting `var` is true (`positive`) or false.
    #[inline]
    pub fn new(var: Var, positive: bool) -> Lit {
        Lit(var.0 * 2 + u32::from(!positive))
    }

    /// Converts a non-zero DIMACS integer (`k` or `-k`, `k >= 1`) to a literal.
    ///
    /// # Panics
    /// Panics if `d == 0`.
    pub fn from_dimacs(d: i32) -> Lit {
        assert!(d != 0, "0 is not a literal");
        Lit::new(Var(d.unsigned_abs() - 1), d > 0)
    }

    /// Converts back to the DIMACS integer.
    pub fn to_dimacs(self) -> i32 {
        let v = self.var().0 as i32 + 1;
        if self.is_positive() {
            v
        } else {
            -v
        }
    }

    /// The literal's variable.
    #[inline]
    pub fn var(self) -> Var {
        Var(self.0 >> 1)
    }

    /// True if the literal is the un-negated variable.
    #[inline]
    pub fn is_positive(self) -> bool {
        self.0 & 1 == 0
    }

    /// Dense index (`2 * var + sign`) for per-literal arrays.
    #[inline]
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

impl Not for Lit {
    type Output = Lit;
    #[inline]
    fn not(self) -> Lit {
        Lit(self.0 ^ 1)
    }
}

impl fmt::Display for Lit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_dimacs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dimacs_round_trip() {
        for d in [-5, -1, 1, 2, 1000] {
            assert_eq!(Lit::from_dimacs(d).to_dimacs(), d);
        }
    }

    #[test]
    fn negation_flips_sign_only() {
        let l = Lit::from_dimacs(3);
        assert_eq!((!l).to_dimacs(), -3);
        assert_eq!(!!l, l);
        assert_eq!(l.var(), (!l).var());
        assert!(l.is_positive() && !(!l).is_positive());
    }

    #[test]
    #[should_panic]
    fn zero_is_not_a_literal() {
        Lit::from_dimacs(0);
    }
}
