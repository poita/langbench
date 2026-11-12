//! Constants and their total order.

use std::fmt;

/// A Datalog constant: an integer or a symbol (a lower-case identifier).
///
/// The derived [`Ord`] is the order required by the language: every integer
/// is smaller than every symbol, integers compare numerically and symbols
/// compare bytewise (a proper prefix sorts first).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Constant {
    /// An integer such as `-5` or `42`.
    Int(i64),
    /// A symbol such as `alice`.
    Sym(String),
}

impl fmt::Display for Constant {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Constant::Int(n) => write!(f, "{n}"),
            Constant::Sym(s) => f.write_str(s),
        }
    }
}

impl From<i64> for Constant {
    fn from(n: i64) -> Self {
        Constant::Int(n)
    }
}

impl From<&str> for Constant {
    fn from(s: &str) -> Self {
        Constant::Sym(s.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integers_sort_before_symbols() {
        assert!(Constant::Int(i64::MAX) < Constant::from("a"));
        assert!(Constant::Int(-3) < Constant::Int(2));
    }

    #[test]
    fn symbols_sort_like_strcmp() {
        let order = ["a", "a0", "a_", "a_b", "aa", "ab", "b"];
        for w in order.windows(2) {
            assert!(Constant::from(w[0]) < Constant::from(w[1]), "{} < {}", w[0], w[1]);
        }
    }

    #[test]
    fn display_is_canonical() {
        assert_eq!(Constant::Int(-5).to_string(), "-5");
        assert_eq!(Constant::from("abc").to_string(), "abc");
    }
}
