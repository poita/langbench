//! Variables, literals and three-valued truth values.

use std::fmt;
use std::ops::Not;

/// A propositional variable, numbered from 0.
///
/// DIMACS variable `k` corresponds to `Var(k - 1)`.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct Var(pub u32);

impl Var {
    /// Index usable for per-variable arrays.
    #[inline]
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

/// A literal: a variable or its negation.
///
/// Internally encoded as `2 * var + sign`, so that literals index arrays densely
/// and negation is a single bit flip.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Lit(u32);

impl Lit {
    /// Creates a literal over `var`; `negated` selects the negative phase.
    #[inline]
    pub fn new(var: Var, negated: bool) -> Lit {
        Lit(var.0 << 1 | negated as u32)
    }

    /// Converts a non-zero DIMACS integer (`k` or `-k`) into a literal.
    ///
    /// # Panics
    /// Panics if `d == 0`.
    pub fn from_dimacs(d: i32) -> Lit {
        assert!(d != 0, "0 is not a literal");
        Lit::new(Var(d.unsigned_abs() - 1), d < 0)
    }

    /// Converts the literal back to its DIMACS integer.
    pub fn to_dimacs(self) -> i32 {
        let v = self.var().0 as i32 + 1;
        if self.is_negated() {
            -v
        } else {
            v
        }
    }

    /// The underlying variable.
    #[inline]
    pub fn var(self) -> Var {
        Var(self.0 >> 1)
    }

    /// Whether this is the negative literal of its variable.
    #[inline]
    pub fn is_negated(self) -> bool {
        self.0 & 1 == 1
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

impl fmt::Debug for Lit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_dimacs())
    }
}

impl fmt::Display for Lit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_dimacs())
    }
}

/// Truth value of a literal under a partial assignment.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LBool {
    /// Assigned true.
    True,
    /// Assigned false.
    False,
    /// Not assigned.
    Undef,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dimacs_round_trip() {
        for d in [-7, -1, 1, 2, 100] {
            assert_eq!(Lit::from_dimacs(d).to_dimacs(), d);
        }
    }

    #[test]
    fn negation_flips_sign_only() {
        let l = Lit::from_dimacs(5);
        assert_eq!((!l).to_dimacs(), -5);
        assert_eq!(!!l, l);
        assert_eq!(l.var(), (!l).var());
        assert!(!l.is_negated() && (!l).is_negated());
    }

    #[test]
    fn indices_are_dense() {
        assert_eq!(Lit::from_dimacs(1).index(), 0);
        assert_eq!(Lit::from_dimacs(-1).index(), 1);
        assert_eq!(Lit::from_dimacs(2).index(), 2);
    }
}
