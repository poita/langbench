//! Error type shared by every module of the crate.

use std::fmt;

/// Everything that can go wrong while reading a database or answering a query.
#[derive(Debug)]
pub enum Error {
    /// An I/O failure while reading the database file.
    Io(std::io::Error),
    /// The database file is malformed (bad header, out-of-range page, truncated
    /// record, ...).
    Corrupt(String),
    /// The query line is not valid under the query grammar.
    Syntax(String),
    /// The query refers to a table, column or index that does not exist, or to
    /// an object of the wrong kind.
    Semantic(String),
}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub(crate) fn corrupt(msg: impl Into<String>) -> Error {
        Error::Corrupt(msg.into())
    }
    pub(crate) fn syntax(msg: impl Into<String>) -> Error {
        Error::Syntax(msg.into())
    }
    pub(crate) fn semantic(msg: impl Into<String>) -> Error {
        Error::Semantic(msg.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io(e) => write!(f, "i/o error: {e}"),
            Error::Corrupt(m) => write!(f, "corrupt database: {m}"),
            Error::Syntax(m) => write!(f, "syntax error: {m}"),
            Error::Semantic(m) => write!(f, "query error: {m}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Error {
        Error::Io(e)
    }
}
