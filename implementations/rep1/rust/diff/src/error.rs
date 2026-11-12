//! Error type shared by the library.

use std::fmt;

/// Everything that can go wrong while parsing a request or applying a script.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The input does not follow the request format.
    Parse(String),
    /// The edit script is not valid for the given file.
    Patch(String),
    /// Writing the output failed.
    Io(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Parse(m) => write!(f, "parse error: {m}"),
            Error::Patch(m) => write!(f, "invalid edit script: {m}"),
            Error::Io(m) => write!(f, "i/o error: {m}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e.to_string())
    }
}
