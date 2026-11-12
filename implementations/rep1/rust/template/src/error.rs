//! Error types shared by every stage of the engine.

use std::fmt;

/// The category of a failure, as reported on the command line
/// (`error: <kind>`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorKind {
    /// The template (or the JSON context / input framing) could not be parsed.
    Syntax,
    /// A template uses a filter that does not exist.
    Filter,
    /// The undefined value was used in a forbidden way.
    Undefined,
    /// An `include`/`extends` named a template that does not exist.
    Template,
    /// An operand or argument had the wrong kind, or an arithmetic error.
    Type,
}

impl ErrorKind {
    /// The lowercase name used in the `error: <kind>` output line.
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorKind::Syntax => "syntax",
            ErrorKind::Filter => "filter",
            ErrorKind::Undefined => "undefined",
            ErrorKind::Template => "template",
            ErrorKind::Type => "type",
        }
    }
}

impl fmt::Display for ErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// An error raised while loading or rendering templates.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    message: String,
}

impl Error {
    /// Creates an error of the given kind with a human-readable message.
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Error { kind, message: message.into() }
    }

    pub(crate) fn syntax(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Syntax, message)
    }

    pub(crate) fn type_error(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Type, message)
    }

    pub(crate) fn undefined(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Undefined, message)
    }

    /// The category of the error.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// A diagnostic message (not part of the stable output contract).
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} error: {}", self.kind, self.message)
    }
}

impl std::error::Error for Error {}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;
