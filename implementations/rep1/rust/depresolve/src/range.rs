//! Version ranges (`*`, exact, `^`, `~`, and comparator lists).

use crate::error::ParseError;
use crate::version::Version;

/// A set of versions, represented internally as a half-open interval.
///
/// Supported syntax (npm semantics for caret and tilde):
///
/// | syntax | meaning |
/// |---|---|
/// | `*` | every version |
/// | `X.Y.Z` | exactly that version |
/// | `^X.Y.Z` | compatible: the leftmost non-zero component stays fixed |
/// | `~X.Y.Z` | `>=X.Y.Z <X.(Y+1).0` |
/// | `>=A <B ...` | one to three comparators (`<`, `<=`, `>`, `>=`), all must hold |
///
/// ```
/// use depresolve::{Range, Version};
/// let r: Range = "^0.2.3".parse().unwrap();
/// assert!(r.matches(&Version::new(0, 2, 9)));
/// assert!(!r.matches(&Version::new(0, 3, 0)));
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Range {
    /// Inclusive lower bound (version key).
    lo: u128,
    /// Exclusive upper bound (version key).
    hi: u128,
}

impl Range {
    /// The range accepting every version.
    pub const ANY: Range = Range {
        lo: 0,
        hi: u128::MAX,
    };

    /// Parses a range from its textual form.
    pub fn parse(s: &str) -> Result<Range, ParseError> {
        let bad = |what: &str| ParseError::new(format!("invalid range {s:?}: {what}"));
        if s == "*" {
            return Ok(Range::ANY);
        }
        if let Some(rest) = s.strip_prefix('^') {
            let v = Version::parse(rest)?;
            let hi = if v.major > 0 {
                Version::new(v.major.checked_add(1).ok_or_else(|| bad("overflow"))?, 0, 0)
            } else if v.minor > 0 {
                Version::new(0, v.minor.checked_add(1).ok_or_else(|| bad("overflow"))?, 0)
            } else {
                Version::new(0, 0, v.patch.checked_add(1).ok_or_else(|| bad("overflow"))?)
            };
            return Ok(Range {
                lo: v.key(),
                hi: hi.key(),
            });
        }
        if let Some(rest) = s.strip_prefix('~') {
            let v = Version::parse(rest)?;
            let hi = Version::new(v.major, v.minor.checked_add(1).ok_or_else(|| bad("overflow"))?, 0);
            return Ok(Range {
                lo: v.key(),
                hi: hi.key(),
            });
        }
        if s.as_bytes().first().is_some_and(u8::is_ascii_digit) {
            let v = Version::parse(s)?;
            return Ok(Range {
                lo: v.key(),
                hi: v.key() + 1,
            });
        }
        let mut range = Range::ANY;
        let mut count = 0;
        for comp in s.split(' ') {
            count += 1;
            let (op, rest) = if let Some(r) = comp.strip_prefix("<=") {
                ("<=", r)
            } else if let Some(r) = comp.strip_prefix(">=") {
                (">=", r)
            } else if let Some(r) = comp.strip_prefix('<') {
                ("<", r)
            } else if let Some(r) = comp.strip_prefix('>') {
                (">", r)
            } else {
                return Err(bad("expected a comparator"));
            };
            let k = Version::parse(rest)?.key();
            match op {
                "<" => range.hi = range.hi.min(k),
                "<=" => range.hi = range.hi.min(k + 1),
                ">" => range.lo = range.lo.max(k + 1),
                _ => range.lo = range.lo.max(k),
            }
        }
        if count > 3 {
            return Err(bad("too many comparators"));
        }
        Ok(range)
    }

    /// Returns true if `v` satisfies this range.
    pub fn matches(&self, v: &Version) -> bool {
        let k = v.key();
        self.lo <= k && k < self.hi
    }

    /// Returns true if no version can satisfy this range.
    pub fn is_empty(&self) -> bool {
        self.lo >= self.hi
    }

    /// Inclusive lower and exclusive upper bound as version keys.
    pub(crate) fn bounds(&self) -> (u128, u128) {
        (self.lo, self.hi)
    }
}

impl std::str::FromStr for Range {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Range::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn accepts(range: &str, v: (u32, u32, u32)) -> bool {
        Range::parse(range)
            .unwrap()
            .matches(&Version::new(v.0, v.1, v.2))
    }

    #[test]
    fn any_and_exact() {
        assert!(accepts("*", (0, 0, 0)));
        assert!(accepts("1.2.3", (1, 2, 3)));
        assert!(!accepts("1.2.3", (1, 2, 4)));
    }

    #[test]
    fn caret() {
        assert!(accepts("^1.2.3", (1, 9, 0)));
        assert!(!accepts("^1.2.3", (2, 0, 0)));
        assert!(!accepts("^1.2.3", (1, 2, 2)));
        assert!(accepts("^0.2.3", (0, 2, 99)));
        assert!(!accepts("^0.2.3", (0, 3, 0)));
        assert!(accepts("^0.0.3", (0, 0, 3)));
        assert!(!accepts("^0.0.3", (0, 0, 4)));
    }

    #[test]
    fn tilde() {
        assert!(accepts("~1.2.0", (1, 2, 7)));
        assert!(!accepts("~1.2.0", (1, 3, 0)));
        assert!(accepts("~0.0.3", (0, 0, 9)));
        assert!(!accepts("~0.0.3", (0, 1, 0)));
    }

    #[test]
    fn comparators() {
        assert!(accepts(">=1.0.0 <2.0.0", (1, 5, 0)));
        assert!(!accepts(">=1.0.0 <2.0.0", (2, 0, 0)));
        assert!(!accepts(">1.0.0", (1, 0, 0)));
        assert!(accepts(">1.0.0", (1, 0, 1)));
        assert!(accepts("<=1.0.0", (1, 0, 0)));
        assert!(!accepts("<1.0.0", (1, 0, 0)));
        assert!(Range::parse(">=2.0.0 <1.0.0").unwrap().is_empty());
    }

    #[test]
    fn rejects_malformed() {
        for s in ["", "^", "=1.0.0", "1.0", ">=1.0.0 foo", "^1.0.0 <2.0.0"] {
            assert!(Range::parse(s).is_err(), "{s:?}");
        }
    }
}
