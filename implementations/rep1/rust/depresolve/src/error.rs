//! Error types.

use std::fmt;

/// An error produced while parsing a version, range, requirement or input document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    /// 1-based line number in the input document, or 0 when not applicable.
    pub line: usize,
    /// Human-readable description of the problem.
    pub message: String,
}

impl ParseError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        ParseError {
            line: 0,
            message: message.into(),
        }
    }

    pub(crate) fn at_line(mut self, line: usize) -> Self {
        self.line = line;
        self
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.line > 0 {
            write!(f, "line {}: {}", self.line, self.message)
        } else {
            write!(f, "{}", self.message)
        }
    }
}

impl std::error::Error for ParseError {}
