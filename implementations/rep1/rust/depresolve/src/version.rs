//! Semantic versions of the form `MAJOR.MINOR.PATCH`.

use crate::error::ParseError;
use std::fmt;
use std::str::FromStr;

/// A semantic version without prerelease or build suffixes.
///
/// Versions order numerically component by component, major first.
///
/// ```
/// use depresolve::Version;
/// assert!("1.10.0".parse::<Version>().unwrap() > "1.9.0".parse().unwrap());
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
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
        Version {
            major,
            minor,
            patch,
        }
    }

    /// Parses `MAJOR.MINOR.PATCH` (no leading zeros, no extra characters).
    pub fn parse(s: &str) -> Result<Version, ParseError> {
        let bad = || ParseError::new(format!("invalid version {s:?}"));
        let mut parts = s.split('.');
        let mut next = || -> Result<u32, ParseError> {
            let p = parts.next().ok_or_else(bad)?;
            parse_num(p).ok_or_else(bad)
        };
        let major = next()?;
        let minor = next()?;
        let patch = next()?;
        if parts.next().is_some() {
            return Err(bad());
        }
        Ok(Version::new(major, minor, patch))
    }

    /// A totally ordered integer key: `a < b` iff `a.key() < b.key()`, and the
    /// key of the immediate successor of `v` is `v.key() + 1`.
    pub(crate) fn key(self) -> u128 {
        ((self.major as u128) << 64) | ((self.minor as u128) << 32) | self.patch as u128
    }
}

fn parse_num(s: &str) -> Option<u32> {
    let b = s.as_bytes();
    if b.is_empty() || !b.iter().all(u8::is_ascii_digit) || (b[0] == b'0' && b.len() > 1) {
        return None;
    }
    s.parse().ok()
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl FromStr for Version {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Version::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_displays() {
        let v: Version = "12.0.345".parse().unwrap();
        assert_eq!(v, Version::new(12, 0, 345));
        assert_eq!(v.to_string(), "12.0.345");
    }

    #[test]
    fn rejects_malformed() {
        for s in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.-3", "a.b.c", "1..2", "1.2.3 "] {
            assert!(Version::parse(s).is_err(), "{s:?}");
        }
    }

    #[test]
    fn orders_numerically() {
        assert!(Version::new(1, 10, 0) > Version::new(1, 9, 0));
        assert!(Version::new(2, 0, 0) > Version::new(1, 99, 99));
        assert!(Version::new(1, 0, 0).key() < Version::new(1, 0, 1).key());
        assert_eq!(Version::new(1, 0, 0).key() + 1, Version::new(1, 0, 1).key());
    }
}
