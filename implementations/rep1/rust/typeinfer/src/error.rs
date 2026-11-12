//! Error types.

use std::fmt;

/// Why a declaration failed to type-check.
///
/// When a declaration has several problems, the kind reported is the first one
/// met by a single left-to-right inference pass (see the crate documentation).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TypeError {
    /// A variable is not in scope.
    Unbound,
    /// Unification would build an infinite type (e.g. `fun x -> x x`).
    Occurs,
    /// Any other unification failure (constructor clash, tuple arity, ...).
    Unify,
}

impl TypeError {
    /// The short name used in the CLI output: `unbound`, `occurs` or `unify`.
    pub fn as_str(self) -> &'static str {
        match self {
            TypeError::Unbound => "unbound",
            TypeError::Occurs => "occurs",
            TypeError::Unify => "unify",
        }
    }
}

impl fmt::Display for TypeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::error::Error for TypeError {}

/// A lexical or syntax error, with the byte offset in the source where it was
/// detected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// Byte offset into the source text.
    pub pos: usize,
    /// Human-readable description.
    pub message: String,
}

impl ParseError {
    pub(crate) fn new(pos: usize, message: impl Into<String>) -> Self {
        ParseError { pos, message: message.into() }
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "syntax error at byte {}: {}", self.pos, self.message)
    }
}

impl std::error::Error for ParseError {}
