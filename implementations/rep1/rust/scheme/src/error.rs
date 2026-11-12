//! Error type shared by the reader, the analyser and the evaluator.

use std::fmt;

/// An error raised while reading, analysing or evaluating a program.
///
/// The first five variants are the *runtime error categories* of the language;
/// [`Error::category`] gives the exact name printed after `error: `.
/// [`Error::Syntax`] is reported for malformed programs, which the
/// specification does not define; it is never produced for well-formed input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A variable was referenced or `set!` but has no binding.
    UnboundVariable,
    /// A primitive received an argument of the wrong type, `apply` got an
    /// improper list, or the operator of an application is not a procedure.
    TypeError,
    /// A procedure was called with an unacceptable number of arguments.
    ArityError,
    /// `quotient` or `remainder` with a zero divisor.
    DivisionByZero,
    /// `(error ...)` was called.
    UserError,
    /// The program text is malformed (not part of the language contract).
    Syntax(String),
}

impl Error {
    /// The category name used in the `error: <category>` output line.
    pub fn category(&self) -> &'static str {
        match self {
            Error::UnboundVariable => "unbound-variable",
            Error::TypeError => "type-error",
            Error::ArityError => "arity-error",
            Error::DivisionByZero => "division-by-zero",
            Error::UserError => "user-error",
            Error::Syntax(_) => "syntax-error",
        }
    }

    pub(crate) fn syntax(msg: impl Into<String>) -> Error {
        Error::Syntax(msg.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Syntax(msg) => write!(f, "syntax-error: {msg}"),
            other => f.write_str(other.category()),
        }
    }
}

impl std::error::Error for Error {}

/// Result alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;
