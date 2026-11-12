//! Error type for pattern parsing and compilation.

use std::fmt;

/// An error produced while turning a pattern into a [`Regex`](crate::Regex).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The pattern is not valid in the supported syntax.
    Syntax {
        /// Byte offset in the pattern at which the problem was detected.
        offset: usize,
        /// Human-readable description.
        message: &'static str,
    },
    /// Expanding counted quantifiers would make the compiled program larger
    /// than [`MAX_PROGRAM_SIZE`](crate::compile::MAX_PROGRAM_SIZE).
    TooLarge,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Syntax { offset, message } => {
                write!(f, "regex syntax error at offset {offset}: {message}")
            }
            Error::TooLarge => write!(f, "regex too large after expanding counted repetitions"),
        }
    }
}

impl std::error::Error for Error {}
