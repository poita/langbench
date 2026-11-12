//! Error types shared by every stage of the pipeline.

use std::fmt;

/// Everything that can go wrong between source text and a computed model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The input is not syntactically valid.
    Parse(ParseError),
    /// A rule has a variable that is not bound by a positive body atom.
    UnsafeRule {
        /// The offending rule, pretty-printed.
        rule: String,
        /// The unbound variable (`_` for an anonymous variable).
        variable: String,
    },
    /// A cycle of the predicate dependency graph contains a negative edge.
    NotStratifiable {
        /// A predicate (`name/arity`) on the offending cycle.
        predicate: String,
    },
}

impl Error {
    /// `true` for the two *semantic* rejections (unsafe rule, no
    /// stratification), as opposed to malformed input.
    pub fn is_semantic(&self) -> bool {
        !matches!(self, Error::Parse(_))
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Parse(e) => write!(f, "{e}"),
            Error::UnsafeRule { rule, variable } => {
                write!(f, "unsafe rule: variable {variable} is not bound by a positive atom in `{rule}`")
            }
            Error::NotStratifiable { predicate } => {
                write!(f, "program is not stratifiable: {predicate} depends negatively on itself")
            }
        }
    }
}

impl std::error::Error for Error {}

impl From<ParseError> for Error {
    fn from(e: ParseError) -> Self {
        Error::Parse(e)
    }
}

/// A syntax error with its position (1-based line and column).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    /// Human readable description.
    pub message: String,
    /// 1-based line number.
    pub line: usize,
    /// 1-based column number.
    pub column: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "syntax error at {}:{}: {}", self.line, self.column, self.message)
    }
}

impl std::error::Error for ParseError {}
