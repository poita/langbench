//! Error type returned when a pattern cannot be compiled.

use std::fmt;

/// What went wrong while parsing or compiling a pattern.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    /// A `(` without a matching `)`.
    UnclosedGroup,
    /// A `)` without a matching `(`.
    UnmatchedCloseParen,
    /// A quantifier with nothing to repeat (start of pattern/group/branch).
    DanglingQuantifier,
    /// A quantifier directly following another quantifier.
    RepeatedQuantifier,
    /// A quantifier applied to `^` or `$`.
    QuantifierOnAnchor,
    /// A malformed `{n}`, `{n,}` or `{n,m}` quantifier.
    InvalidQuantifier,
    /// A counted quantifier bound is larger than [`MAX_REPEAT`](crate::MAX_REPEAT).
    RepeatTooLarge,
    /// A backslash followed by a letter/digit that is not a supported escape,
    /// or a trailing backslash.
    InvalidEscape,
    /// A metacharacter (`]`, `}`) that may only appear escaped.
    UnexpectedMeta,
    /// A `[` without a closing `]`.
    UnclosedClass,
    /// A class with no items, such as `[]` or `[^]`.
    EmptyClass,
    /// A class range whose endpoints are out of order or malformed.
    InvalidRange,
    /// Groups are nested more deeply than [`MAX_NESTING`](crate::MAX_NESTING).
    NestingTooDeep,
    /// Counted-quantifier expansion produced an unreasonably large program.
    PatternTooLarge,
}

/// An error produced when compiling a pattern, with the byte offset in the
/// pattern at which it was detected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    position: usize,
}

impl Error {
    pub(crate) fn new(kind: ErrorKind, position: usize) -> Self {
        Error { kind, position }
    }

    /// The category of the error.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// Byte offset into the pattern where the problem was detected.
    pub fn position(&self) -> usize {
        self.position
    }
}

impl fmt::Display for ErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let msg = match self {
            ErrorKind::UnclosedGroup => "unclosed group",
            ErrorKind::UnmatchedCloseParen => "unmatched closing parenthesis",
            ErrorKind::DanglingQuantifier => "quantifier has nothing to repeat",
            ErrorKind::RepeatedQuantifier => "quantifier follows another quantifier",
            ErrorKind::QuantifierOnAnchor => "quantifier applied to an anchor",
            ErrorKind::InvalidQuantifier => "malformed counted quantifier",
            ErrorKind::RepeatTooLarge => "repeat count too large",
            ErrorKind::InvalidEscape => "invalid escape sequence",
            ErrorKind::UnexpectedMeta => "unescaped metacharacter",
            ErrorKind::UnclosedClass => "unclosed character class",
            ErrorKind::EmptyClass => "empty character class",
            ErrorKind::InvalidRange => "invalid character range",
            ErrorKind::NestingTooDeep => "groups nested too deeply",
            ErrorKind::PatternTooLarge => "pattern expands to too large a program",
        };
        f.write_str(msg)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at offset {}", self.kind, self.position)
    }
}

impl std::error::Error for Error {}
