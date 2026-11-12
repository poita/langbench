//! Error type for parsing rules and requests.

use std::fmt;

/// An error produced while parsing a rule, date-time or request line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    message: String,
}

impl ParseError {
    pub(crate) fn new(message: impl Into<String>) -> ParseError {
        ParseError { message: message.into() }
    }

    /// Human-readable description of the problem.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ParseError {}
