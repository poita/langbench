//! Error types.

use std::fmt;

/// An error found while parsing a TOML document.
///
/// Carries a short human-readable message and the 1-based line and column
/// (counted in characters) where the problem was detected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    message: String,
    line: usize,
    column: usize,
}

impl ParseError {
    pub(crate) fn at(src: &[u8], offset: usize, message: impl Into<String>) -> Self {
        let offset = offset.min(src.len());
        let before = &src[..offset];
        let line = before.iter().filter(|&&b| b == b'\n').count() + 1;
        let line_start = before
            .iter()
            .rposition(|&b| b == b'\n')
            .map_or(0, |i| i + 1);
        // Count characters, not bytes: skip UTF-8 continuation bytes.
        let column = before[line_start..]
            .iter()
            .filter(|&&b| (b & 0xC0) != 0x80)
            .count()
            + 1;
        ParseError {
            message: message.into(),
            line,
            column,
        }
    }

    /// The error message, without position information.
    pub fn message(&self) -> &str {
        &self.message
    }

    /// 1-based line number of the error.
    pub fn line(&self) -> usize {
        self.line
    }

    /// 1-based column (in characters) of the error.
    pub fn column(&self) -> usize {
        self.column
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at line {}, column {}", self.message, self.line, self.column)
    }
}

impl std::error::Error for ParseError {}

/// An error found while reading tagged JSON or encoding a tree as TOML.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaggedError {
    message: String,
}

impl TaggedError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        TaggedError {
            message: message.into(),
        }
    }

    /// The error message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for TaggedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for TaggedError {}
