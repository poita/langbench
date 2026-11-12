//! Semantic versions and version ranges.
//!
//! Only plain `MAJOR.MINOR.PATCH` versions are supported (no prerelease or
//! build metadata). Every range supported by the input format is compiled to a
//! half-open interval of versions, [`Interval`], which makes membership tests
//! and (after sorting) index-range lookups trivial.

use std::fmt;

use crate::error::ParseError;

/// A semantic version `MAJOR.MINOR.PATCH`, ordered numerically component by
/// component.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Version {
    /// Major component.
    pub major: u32,
    /// Minor component.
    pub minor: u32,
    /// Patch component.
    pub patch: u32,
}

impl Version {
    /// Creates a version from its three components.
    pub const fn new(major: u32, minor: u32, patch: u32) -> Self {
        Version { major, minor, patch }
    }

    /// The smallest version strictly greater than `self`.
    fn successor(self) -> Version {
        Version::new(self.major, self.minor, self.patch + 1)
    }

    /// Parses `X.Y.Z` where every component is `0` or a decimal number
    /// without leading zeros.
    pub fn parse(s: &str) -> Result<Version, ParseError> {
        let bad = || ParseError::new(format!("invalid version `{s}`"));
        let mut parts = s.split('.');
        let mut next = || -> Result<u32, ParseError> {
            let p = parts.next().ok_or_else(bad)?;
            let ok = !p.is_empty()
                && p.bytes().all(|b| b.is_ascii_digit())
                && (p == "0" || !p.starts_with('0'));
            if !ok {
                return Err(bad());
            }
            p.parse::<u32>().map_err(|_| bad())
        };
        let v = Version::new(next()?, next()?, next()?);
        if parts.next().is_some() {
            return Err(bad());
        }
        Ok(v)
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl std::str::FromStr for Version {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Version::parse(s)
    }
}

/// A half-open interval `[lo, hi)` of versions. `hi == None` means unbounded
/// above.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Interval {
    /// Inclusive lower bound.
    pub lo: Version,
    /// Exclusive upper bound, or `None` for no upper bound.
    pub hi: Option<Version>,
}

impl Interval {
    /// The interval accepting every version.
    pub const ALL: Interval = Interval { lo: Version::new(0, 0, 0), hi: None };

    /// Whether `v` lies inside the interval.
    pub fn contains(&self, v: Version) -> bool {
        v >= self.lo && self.hi.map_or(true, |hi| v < hi)
    }

    /// Whether no version at all lies inside the interval.
    pub fn is_empty(&self) -> bool {
        self.hi.map_or(false, |hi| hi <= self.lo)
    }

    /// The intersection of two intervals.
    pub fn intersect(&self, other: &Interval) -> Interval {
        let hi = match (self.hi, other.hi) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        };
        Interval { lo: self.lo.max(other.lo), hi }
    }

    /// Parses a range expression:
    ///
    /// * `*` — any version
    /// * `X.Y.Z` — exactly that version
    /// * `^X.Y.Z` — caret: keeps the leftmost non-zero component fixed
    /// * `~X.Y.Z` — tilde: keeps major and minor fixed
    /// * `<A`, `<=A`, `>A`, `>=A` — one to three space-separated comparators,
    ///   all of which must hold
    pub fn parse(s: &str) -> Result<Interval, ParseError> {
        let bad = || ParseError::new(format!("invalid range `{s}`"));
        if s == "*" {
            return Ok(Interval::ALL);
        }
        if let Some(rest) = s.strip_prefix('^') {
            let v = Version::parse(rest)?;
            let hi = if v.major > 0 {
                Version::new(v.major + 1, 0, 0)
            } else if v.minor > 0 {
                Version::new(0, v.minor + 1, 0)
            } else {
                Version::new(0, 0, v.patch + 1)
            };
            return Ok(Interval { lo: v, hi: Some(hi) });
        }
        if let Some(rest) = s.strip_prefix('~') {
            let v = Version::parse(rest)?;
            return Ok(Interval { lo: v, hi: Some(Version::new(v.major, v.minor + 1, 0)) });
        }
        if s.starts_with(|c: char| c.is_ascii_digit()) {
            let v = Version::parse(s)?;
            return Ok(Interval { lo: v, hi: Some(v.successor()) });
        }
        let mut acc = Interval::ALL;
        for comp in s.split(' ') {
            let (op, rest) = if let Some(r) = comp.strip_prefix("<=") {
                ("<=", r)
            } else if let Some(r) = comp.strip_prefix(">=") {
                (">=", r)
            } else if let Some(r) = comp.strip_prefix('<') {
                ("<", r)
            } else if let Some(r) = comp.strip_prefix('>') {
                (">", r)
            } else {
                return Err(bad());
            };
            let v = Version::parse(rest)?;
            let c = match op {
                "<" => Interval { lo: Version::new(0, 0, 0), hi: Some(v) },
                "<=" => Interval { lo: Version::new(0, 0, 0), hi: Some(v.successor()) },
                ">" => Interval { lo: v.successor(), hi: None },
                _ => Interval { lo: v, hi: None },
            };
            acc = acc.intersect(&c);
        }
        Ok(acc)
    }
}

impl std::str::FromStr for Interval {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Interval::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }
    fn accepts(range: &str, ver: &str) -> bool {
        range.parse::<Interval>().unwrap().contains(v(ver))
    }

    #[test]
    fn numeric_ordering() {
        assert!(v("1.10.0") > v("1.9.0"));
        assert!(v("2.0.0") > v("1.999999.999999"));
    }

    #[test]
    fn version_parse_rejects_garbage() {
        for s in ["1.2", "1.2.3.4", "01.2.3", "1.-2.3", "a.b.c", "", "1..3"] {
            assert!(Version::parse(s).is_err(), "{s}");
        }
        assert_eq!(Version::parse("0.0.0").unwrap(), Version::new(0, 0, 0));
        assert_eq!(v("1000000.1000000.1000000").to_string(), "1000000.1000000.1000000");
    }

    #[test]
    fn star_and_exact() {
        assert!(accepts("*", "0.0.0"));
        assert!(accepts("1.2.3", "1.2.3"));
        assert!(!accepts("1.2.3", "1.2.4"));
        assert!(!accepts("1.2.3", "1.2.2"));
    }

    #[test]
    fn caret() {
        assert!(accepts("^1.2.3", "1.2.3"));
        assert!(accepts("^1.2.3", "1.99.0"));
        assert!(!accepts("^1.2.3", "2.0.0"));
        assert!(!accepts("^1.2.3", "1.2.2"));
        assert!(accepts("^0.2.3", "0.2.9"));
        assert!(!accepts("^0.2.3", "0.3.0"));
        assert!(accepts("^0.0.3", "0.0.3"));
        assert!(!accepts("^0.0.3", "0.0.4"));
        assert!(!accepts("^0.0.3", "0.0.2"));
    }

    #[test]
    fn tilde() {
        assert!(accepts("~1.2.3", "1.2.9"));
        assert!(!accepts("~1.2.3", "1.3.0"));
        assert!(accepts("~0.0.3", "0.0.9"));
        assert!(accepts("~0.0.3", "0.0.3"));
        assert!(!accepts("~0.0.3", "0.1.0"));
    }

    #[test]
    fn comparators() {
        assert!(accepts(">=1.0.0 <2.0.0", "1.5.0"));
        assert!(!accepts(">=1.0.0 <2.0.0", "2.0.0"));
        assert!(!accepts(">1.0.0", "1.0.0"));
        assert!(accepts(">1.0.0", "1.0.1"));
        assert!(accepts("<=1.0.0", "1.0.0"));
        assert!(!accepts("<1.0.0", "1.0.0"));
        assert!(accepts(">1.0.0 >=1.2.0 <=1.4.0", "1.4.0"));
        assert!(!accepts(">1.0.0 >=1.2.0 <=1.4.0", "1.1.0"));
        assert!("<=0.0.0 >0.0.0".parse::<Interval>().unwrap().is_empty());
        assert!(">=2.0.0 <1.0.0".parse::<Interval>().unwrap().is_empty());
    }

    #[test]
    fn range_parse_rejects_garbage() {
        for s in ["", "=1.0.0", "^1.0", ">= 1.0.0", "<1.0.0 foo"] {
            assert!(Interval::parse(s).is_err(), "{s}");
        }
    }
}
