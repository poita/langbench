//! The error type shared by every module in the crate.

use std::fmt;

/// Everything that can go wrong while parsing a schema, decoding bytes,
/// parsing text or interpreting a request line.
///
/// The variants carry static descriptions so that failing on malformed input
/// (which the CLI treats as an ordinary result) never allocates.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The schema source is malformed.
    Schema(String),
    /// The named message does not exist in the schema.
    UnknownMessage(String),
    /// A hex string is malformed.
    Hex(&'static str),
    /// A wire-format byte string is malformed.
    Wire(&'static str),
    /// A text-form message is malformed or does not fit its schema.
    Text {
        /// Byte offset in the text where the problem was detected.
        offset: usize,
        /// What was wrong.
        message: &'static str,
    },
    /// A request line is malformed.
    Request(&'static str),
}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Schema(m) => write!(f, "invalid schema: {m}"),
            Error::UnknownMessage(n) => write!(f, "unknown message type `{n}`"),
            Error::Hex(m) => write!(f, "invalid hex: {m}"),
            Error::Wire(m) => write!(f, "invalid wire data: {m}"),
            Error::Text { offset, message } => {
                write!(f, "invalid text at byte {offset}: {message}")
            }
            Error::Request(m) => write!(f, "invalid request: {m}"),
        }
    }
}

impl std::error::Error for Error {}
