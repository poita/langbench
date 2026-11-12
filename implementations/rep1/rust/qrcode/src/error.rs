//! Error type for encoding and query parsing.

use std::fmt;

/// Errors produced by the encoder and the query parser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The payload does not fit in any version (1..=40) at the requested
    /// error correction level.
    DataTooLong,
    /// A query line could not be parsed; the string says why.
    BadQuery(String),
    /// A version number outside `1..=40` was supplied.
    InvalidVersion(u8),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::DataTooLong => f.write_str("data too long for any QR version at this level"),
            Error::BadQuery(msg) => write!(f, "bad query: {msg}"),
            Error::InvalidVersion(v) => write!(f, "invalid version {v} (must be 1..=40)"),
        }
    }
}

impl std::error::Error for Error {}
