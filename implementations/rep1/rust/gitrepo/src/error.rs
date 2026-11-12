//! The error type shared by every module of the crate.

use std::fmt;

/// Everything that can go wrong while reading a repository.
///
/// The variants are coarse on purpose: the command-line tool turns every one
/// of them into the same `error` answer, and library users mostly want a
/// human-readable message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A file could not be read.
    Io(String),
    /// An object, pack, index or compressed stream is damaged.
    Corrupt(String),
    /// An object that was asked for is not in the repository.
    NotFound(String),
    /// A revision, path or command line is malformed or does not resolve.
    Invalid(String),
}

/// Shorthand for `std::result::Result<T, gitrepo::Error>`.
pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub(crate) fn corrupt(msg: impl Into<String>) -> Error {
        Error::Corrupt(msg.into())
    }
    pub(crate) fn invalid(msg: impl Into<String>) -> Error {
        Error::Invalid(msg.into())
    }
    pub(crate) fn not_found(msg: impl Into<String>) -> Error {
        Error::NotFound(msg.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io(m) => write!(f, "I/O error: {m}"),
            Error::Corrupt(m) => write!(f, "corrupt data: {m}"),
            Error::NotFound(m) => write!(f, "not found: {m}"),
            Error::Invalid(m) => write!(f, "invalid: {m}"),
        }
    }
}

impl std::error::Error for Error {}
