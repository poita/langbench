//! Error types.

use std::borrow::Cow;
use std::fmt;

use crate::value::Value;

/// A runtime error raised while evaluating a filter (for example indexing a
/// number with a string, or calling `error`).
#[derive(Debug, Clone)]
pub enum Error {
    /// An error with a human-readable message.
    Message(Cow<'static, str>),
    /// An error raised by the `error(f)` builtin, carrying the raised value.
    Value(Value),
}

impl Error {
    /// Creates an error from a message.
    pub fn msg(message: impl Into<Cow<'static, str>>) -> Error {
        Error::Message(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Message(m) => f.write_str(m),
            Error::Value(Value::String(s)) => f.write_str(s),
            Error::Value(v) => write!(f, "{} (not a string)", v),
        }
    }
}

impl std::error::Error for Error {}

/// A syntax error in a filter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    /// What went wrong.
    pub message: String,
    /// Byte offset into the filter text where the problem was detected.
    pub offset: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "syntax error at byte {}: {}", self.offset, self.message)
    }
}

impl std::error::Error for ParseError {}

/// A syntax error in a JSON document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonError {
    /// What went wrong.
    pub message: String,
    /// Byte offset into the document where the problem was detected.
    pub offset: usize,
}

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid JSON at byte {}: {}", self.offset, self.message)
    }
}

impl std::error::Error for JsonError {}
