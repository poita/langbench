//! Error type shared by the validator, the parser and the public API.

use std::fmt;

/// What went wrong while reading a document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    /// The input is not well-formed UTF-8 (RFC 3629).
    InvalidUtf8,
    /// The input starts with a byte-order mark.
    ByteOrderMark,
    /// The input ended in the middle of a value.
    UnexpectedEnd,
    /// A byte that cannot start or continue the construct being parsed.
    UnexpectedByte,
    /// A malformed escape sequence, including bad surrogate pairing.
    InvalidEscape,
    /// A raw control character (U+0000–U+001F) inside a string.
    ControlCharacter,
    /// A malformed number lexeme.
    InvalidNumber,
    /// Non-whitespace data after the top-level value.
    TrailingData,
    /// Arrays/objects nested deeper than [`MAX_DEPTH`](crate::MAX_DEPTH).
    TooDeep,
}

/// An error together with the byte offset at which it was detected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Error {
    /// The category of the failure.
    pub kind: ErrorKind,
    /// Byte offset into the input where the failure was detected.
    pub offset: usize,
}

impl Error {
    pub(crate) fn new(kind: ErrorKind, offset: usize) -> Self {
        Error { kind, offset }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let what = match self.kind {
            ErrorKind::InvalidUtf8 => "invalid UTF-8",
            ErrorKind::ByteOrderMark => "byte-order mark not allowed",
            ErrorKind::UnexpectedEnd => "unexpected end of input",
            ErrorKind::UnexpectedByte => "unexpected byte",
            ErrorKind::InvalidEscape => "invalid escape sequence",
            ErrorKind::ControlCharacter => "unescaped control character in string",
            ErrorKind::InvalidNumber => "invalid number",
            ErrorKind::TrailingData => "trailing data after document",
            ErrorKind::TooDeep => "nesting too deep",
        };
        write!(f, "{} at byte {}", what, self.offset)
    }
}

impl std::error::Error for Error {}
