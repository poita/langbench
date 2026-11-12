//! Template errors.

use std::fmt;

/// The category of a template error.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ErrorKind {
    /// The template could not be lexed or parsed.
    Syntax,
    /// A loaded template uses an unknown filter.
    Filter,
    /// The undefined value was used in a way that is not allowed.
    Undefined,
    /// An `include` or `extends` named a template that does not exist.
    Template,
    /// An operand or argument had the wrong kind, or an arithmetic error occurred.
    Type,
}

impl ErrorKind {
    /// The lower-case name of the kind (`"syntax"`, `"filter"`, ...).
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

/// An error raised while loading or rendering a template.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    message: String,
}

impl Error {
    pub(crate) fn new(kind: ErrorKind, message: impl Into<String>) -> Error {
        Error {
            kind,
            message: message.into(),
        }
    }

    pub(crate) fn syntax(message: impl Into<String>) -> Error {
        Error::new(ErrorKind::Syntax, message)
    }

    pub(crate) fn type_error(message: impl Into<String>) -> Error {
        Error::new(ErrorKind::Type, message)
    }

    pub(crate) fn undefined(message: impl Into<String>) -> Error {
        Error::new(ErrorKind::Undefined, message)
    }

    /// The category of the error.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// A human-readable description.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} error: {}", self.kind.as_str(), self.message)
    }
}

impl std::error::Error for Error {}

pub(crate) type Result<T> = std::result::Result<T, Error>;
