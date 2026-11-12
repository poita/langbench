//! Error type for input parsing.

use std::fmt;

/// An error found while parsing a registry/manifest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// 1-based line number, when known.
    pub line: Option<usize>,
    /// Human-readable description.
    pub message: String,
}

impl ParseError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        ParseError { line: None, message: message.into() }
    }

    pub(crate) fn at_line(mut self, line: usize) -> Self {
        self.line = Some(line);
        self
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.line {
            Some(l) => write!(f, "line {l}: {}", self.message),
            None => f.write_str(&self.message),
        }
    }
}

impl std::error::Error for ParseError {}
