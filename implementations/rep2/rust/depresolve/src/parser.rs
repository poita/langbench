//! Parser for the textual registry + root manifest format.
//!
//! ```text
//! a 1.0.0: c ^1.0.0
//! b 1.0.0: c ~1.2.0, d >=1.0.0 <2.0.0
//! c 1.2.5:
//! root: a *, b *
//! ```

use crate::error::ParseError;
use crate::registry::{Problem, RegistryBuilder};
use crate::version::{Interval, Version};

/// Parses a whole input (registry lines followed by the root line).
///
/// The last non-empty line must be the root line `root:` + requirements.
pub fn parse(input: &str) -> Result<Problem, ParseError> {
    let mut builder = RegistryBuilder::new();
    let mut root_seen = false;
    for (i, line) in input.lines().enumerate() {
        let n = i + 1;
        if line.is_empty() {
            continue;
        }
        if root_seen {
            return Err(ParseError::new("content after the root line").at_line(n));
        }
        let (head, reqs) = line
            .split_once(':')
            .ok_or_else(|| ParseError::new("missing `:`").at_line(n))?;
        let reqs = parse_requirements(reqs).map_err(|e| e.at_line(n))?;
        let reqs: Vec<(&str, Interval)> = reqs;
        if head == "root" {
            builder.set_root(&reqs);
            root_seen = true;
        } else {
            let (name, ver) = head
                .split_once(' ')
                .ok_or_else(|| ParseError::new("expected `name version`").at_line(n))?;
            let version = Version::parse(ver).map_err(|e| e.at_line(n))?;
            builder.add_version(name, version, &reqs);
        }
    }
    if !root_seen {
        return Err(ParseError::new("missing root line"));
    }
    Ok(builder.build())
}

/// Parses the text after the `:`: empty, or `" " req {", " req}`.
fn parse_requirements(s: &str) -> Result<Vec<(&str, Interval)>, ParseError> {
    if s.is_empty() {
        return Ok(Vec::new());
    }
    let s = s
        .strip_prefix(' ')
        .ok_or_else(|| ParseError::new("expected a space after `:`"))?;
    s.split(", ")
        .map(|req| {
            let (name, range) = req
                .split_once(' ')
                .ok_or_else(|| ParseError::new(format!("invalid requirement `{req}`")))?;
            Ok((name, Interval::parse(range)?))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_example() {
        let p = parse("a 1.0.0: c ^1.0.0\nc 1.1.0:\nroot: a *\n").unwrap();
        assert_eq!(p.registry.package_count(), 2);
        assert_eq!(p.root.len(), 1);
        let a = p.registry.id_of("a").unwrap();
        assert_eq!(p.registry.requirements(a, 0).len(), 1);
    }

    #[test]
    fn empty_root() {
        let p = parse("root:\n").unwrap();
        assert!(p.root.is_empty());
    }

    #[test]
    fn missing_root_is_an_error() {
        assert!(parse("a 1.0.0:\n").is_err());
        assert!(parse("").is_err());
    }

    #[test]
    fn malformed_lines_report_line_numbers() {
        let e = parse("a 1.0.0:\nb 1.0: x *\nroot:\n").unwrap_err();
        assert_eq!(e.line, Some(2));
        assert!(parse("a 1.0.0: x\nroot:\n").is_err());
        assert!(parse("a 1.0.0:x *\nroot:\n").is_err());
    }

    #[test]
    fn multi_comparator_requirements_split_on_commas_only() {
        let p = parse("a 1.0.0: b >=1.0.0 <2.0.0, c *\nroot: a *\n").unwrap();
        let a = p.registry.id_of("a").unwrap();
        assert_eq!(p.registry.requirements(a, 0).len(), 2);
    }
}
