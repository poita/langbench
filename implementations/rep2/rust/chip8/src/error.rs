//! Error types.

use std::error::Error;
use std::fmt;

/// Error returned when a ROM cannot be loaded into memory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RomError {
    /// The ROM does not fit between `0x200` and the end of memory.
    TooLarge {
        /// Size of the offending ROM in bytes.
        len: usize,
        /// Maximum number of bytes that fit.
        max: usize,
    },
}

impl fmt::Display for RomError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RomError::TooLarge { len, max } => {
                write!(f, "ROM is {len} bytes, but at most {max} bytes fit in memory")
            }
        }
    }
}

impl Error for RomError {}

/// Error returned when the textual job description is malformed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// A required line (`rom` or `cycles`) is missing.
    MissingLine(&'static str),
    /// The ROM line is not an even-length string of hexadecimal digits.
    InvalidRom(String),
    /// The cycle count is not a valid unsigned decimal integer.
    InvalidCycles(String),
    /// A key-schedule event could not be parsed.
    InvalidEvent(String),
    /// Key-schedule cycles are not strictly increasing.
    EventsNotIncreasing(u64),
    /// A key-schedule event lies beyond the cycle budget.
    EventAfterEnd(u64),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::MissingLine(what) => write!(f, "missing {what} line"),
            ParseError::InvalidRom(s) => write!(f, "invalid ROM hex: {s:?}"),
            ParseError::InvalidCycles(s) => write!(f, "invalid cycle count: {s:?}"),
            ParseError::InvalidEvent(s) => write!(f, "invalid key event: {s:?}"),
            ParseError::EventsNotIncreasing(c) => {
                write!(f, "key event cycle {c} is not greater than the previous one")
            }
            ParseError::EventAfterEnd(c) => {
                write!(f, "key event cycle {c} exceeds the cycle count")
            }
        }
    }
}

impl Error for ParseError {}
