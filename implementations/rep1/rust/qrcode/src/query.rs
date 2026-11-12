//! Parsing of the CLI's query lines: `<ecl> <mask> <text>`.

use crate::{Ecl, Error, MaskChoice};

/// A parsed query line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query<'a> {
    /// Requested error correction level.
    pub ecl: Ecl,
    /// Requested mask selection.
    pub mask: MaskChoice,
    /// Payload bytes (everything after the second space).
    pub text: &'a [u8],
}

/// Parses one line (without its line terminator).
pub fn parse_line(line: &[u8]) -> Result<Query<'_>, Error> {
    let bad = |msg: &str| Error::BadQuery(msg.to_string());
    let first = line
        .iter()
        .position(|&b| b == b' ')
        .ok_or_else(|| bad("missing fields"))?;
    let rest = &line[first + 1..];
    let second = rest
        .iter()
        .position(|&b| b == b' ')
        .ok_or_else(|| bad("missing text"))?;

    let ecl = match &line[..first] {
        [c] => Ecl::from_letter(*c),
        _ => None,
    }
    .ok_or_else(|| bad("error correction level must be L, M, Q or H"))?;

    let mask = match &rest[..second] {
        b"auto" => MaskChoice::Auto,
        [d @ b'0'..=b'7'] => MaskChoice::Fixed(d - b'0'),
        _ => return Err(bad("mask must be 0-7 or auto")),
    };
    let text = &rest[second + 1..];
    if text.is_empty() {
        return Err(bad("empty text"));
    }
    Ok(Query { ecl, mask, text })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fields() {
        let q = parse_line(b"M 0 HELLO WORLD").unwrap();
        assert_eq!(q.ecl, Ecl::Medium);
        assert_eq!(q.mask, MaskChoice::Fixed(0));
        assert_eq!(q.text, b"HELLO WORLD");
        let q = parse_line("H auto h\u{e9}llo".as_bytes()).unwrap();
        assert_eq!(q.mask, MaskChoice::Auto);
        assert_eq!(q.text, "h\u{e9}llo".as_bytes());
    }

    #[test]
    fn rejects_malformed() {
        assert!(parse_line(b"").is_err());
        assert!(parse_line(b"M 0").is_err());
        assert!(parse_line(b"X 0 abc").is_err());
        assert!(parse_line(b"M 8 abc").is_err());
        assert!(parse_line(b"M 0 ").is_err());
    }
}
