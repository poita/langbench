//! Parser for the line-oriented input format.
//!
//! ```text
//! name 1.2.3: dep ^1.0.0, other >=1.0.0 <2.0.0
//! root: name *
//! ```

use crate::error::ParseError;
use crate::range::Range;
use crate::registry::{Registry, Requirement};
use crate::version::Version;

/// A parsed input document: the registry and the root manifest.
#[derive(Debug, Clone)]
pub struct Input {
    /// All package versions declared in the document.
    pub registry: Registry,
    /// The root requirements, in the order listed.
    pub root: Vec<Requirement>,
}

/// Parses a requirement list: either empty or `" req, req, ..."` (leading space).
pub fn parse_requirements(s: &str) -> Result<Vec<Requirement>, ParseError> {
    if s.is_empty() {
        return Ok(Vec::new());
    }
    let body = s
        .strip_prefix(' ')
        .ok_or_else(|| ParseError::new("expected a space after ':'"))?;
    body.split(", ")
        .map(|item| {
            let (name, range) = item
                .split_once(' ')
                .ok_or_else(|| ParseError::new(format!("invalid requirement {item:?}")))?;
            check_name(name)?;
            Ok(Requirement::new(name, Range::parse(range)?))
        })
        .collect()
}

fn check_name(name: &str) -> Result<(), ParseError> {
    let b = name.as_bytes();
    let ok = !b.is_empty()
        && b[0].is_ascii_lowercase()
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-');
    if ok {
        Ok(())
    } else {
        Err(ParseError::new(format!("invalid package name {name:?}")))
    }
}

/// Parses a whole input document. The last line must be the root line.
pub fn parse_input(text: &str) -> Result<Input, ParseError> {
    let mut registry = Registry::new();
    let mut root: Option<Vec<Requirement>> = None;
    for (i, line) in text.lines().enumerate() {
        let lineno = i + 1;
        if root.is_some() {
            return Err(ParseError::new("content after the root line").at_line(lineno));
        }
        if let Some(reqs) = line.strip_prefix("root:") {
            root = Some(parse_requirements(reqs).map_err(|e| e.at_line(lineno))?);
            continue;
        }
        let (head, reqs) = line
            .split_once(':')
            .ok_or_else(|| ParseError::new("missing ':'").at_line(lineno))?;
        let (name, version) = head
            .split_once(' ')
            .ok_or_else(|| ParseError::new("expected `name version`").at_line(lineno))?;
        check_name(name).map_err(|e| e.at_line(lineno))?;
        let version = Version::parse(version).map_err(|e| e.at_line(lineno))?;
        let reqs = parse_requirements(reqs).map_err(|e| e.at_line(lineno))?;
        registry.add(name, version, reqs);
    }
    match root {
        Some(root) => Ok(Input { registry, root }),
        None => Err(ParseError::new("missing root line")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_document() {
        let input = parse_input("a 1.0.0: b ^1.0.0, c >=1.0.0 <2.0.0\nb 1.0.0:\nroot: a *\n").unwrap();
        assert_eq!(input.registry.package_count(), 2);
        assert_eq!(input.registry.releases("a")[0].requirements.len(), 2);
        assert_eq!(input.root.len(), 1);
    }

    #[test]
    fn empty_root() {
        let input = parse_input("root:\n").unwrap();
        assert!(input.root.is_empty());
    }

    #[test]
    fn errors() {
        assert!(parse_input("").is_err());
        assert!(parse_input("a 1.0.0:\n").is_err());
        assert!(parse_input("root:\na 1.0.0:\n").is_err());
        assert!(parse_input("a 1.0:\nroot:\n").is_err());
        assert_eq!(parse_input("a 1.0.0: b\nroot:\n").unwrap_err().line, 1);
    }
}
