//! Errors reported by the library API (as opposed to spreadsheet error
//! *values*, which are [`ErrorCode`](crate::ErrorCode)s stored in cells).

use crate::parser::ParseError;
use std::fmt;

/// A failure to interpret a name, content string or command.
#[derive(Clone, PartialEq, Debug)]
pub enum Error {
    /// The text is not a valid cell name.
    InvalidCell(String),
    /// The content is not a formula, a string literal or a number literal.
    InvalidContent(String),
    /// The formula has a syntax error.
    Formula(ParseError),
    /// The command line is not understood.
    InvalidCommand(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidCell(s) => write!(f, "invalid cell name: {s:?}"),
            Error::InvalidContent(s) => write!(f, "invalid cell content: {s:?}"),
            Error::Formula(e) => e.fmt(f),
            Error::InvalidCommand(s) => write!(f, "invalid command: {s:?}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Formula(e) => Some(e),
            _ => None,
        }
    }
}

impl From<ParseError> for Error {
    fn from(e: ParseError) -> Error {
        Error::Formula(e)
    }
}
