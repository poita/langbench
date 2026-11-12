//! Error type shared by every stage of statement processing.

use std::fmt;

/// Why a statement failed.
///
/// A failing statement never changes the database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The statement does not match the grammar (including invalid tokens).
    Syntax(String),
    /// The statement is well formed but refers to unknown or ambiguous names,
    /// misuses aggregates, has the wrong arity, and so on.
    Semantic(String),
}

impl Error {
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
            Error::Syntax(m) => write!(f, "syntax error: {m}"),
            Error::Semantic(m) => write!(f, "error: {m}"),
        }
    }
}

impl std::error::Error for Error {}

/// Convenient alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;
