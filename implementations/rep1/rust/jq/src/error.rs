//! The error type shared by parsing and evaluation.

use std::fmt;

/// The category of an [`Error`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    /// The filter text is not valid in the supported jq subset.
    Syntax,
    /// The JSON document is malformed.
    Json,
    /// A runtime error raised while evaluating a filter (type errors, `error`, ...).
    Runtime,
    /// Internal control-flow marker used to implement `try`; never escapes the library.
    #[doc(hidden)]
    Control,
}

/// An error produced while parsing a filter, parsing JSON, or evaluating a filter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    message: String,
}

impl Error {
    pub(crate) fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Error { kind, message: message.into() }
    }

    pub(crate) fn syntax(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Syntax, message)
    }

    pub(crate) fn json(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Json, message)
    }

    pub(crate) fn runtime(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Runtime, message)
    }

    pub(crate) fn control() -> Self {
        Self::new(ErrorKind::Control, "")
    }

    /// The category of this error.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// The human-readable message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.kind {
            ErrorKind::Syntax => write!(f, "syntax error: {}", self.message),
            ErrorKind::Json => write!(f, "invalid JSON: {}", self.message),
            ErrorKind::Runtime | ErrorKind::Control => f.write_str(&self.message),
        }
    }
}

impl std::error::Error for Error {}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;
