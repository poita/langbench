//! Error type for input parsing and machine construction.

use std::fmt;

/// An error found while parsing the input or building a machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// A required line is missing; the payload names it.
    MissingLine(&'static str),
    /// The ROM line is not valid, even-length lowercase hexadecimal.
    BadRom(String),
    /// The ROM is empty or larger than the 3584 bytes that fit in memory.
    RomSize(usize),
    /// The cycle count is not a valid decimal integer.
    BadCycles(String),
    /// A key-schedule event is malformed or out of order.
    BadEvent(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::MissingLine(what) => write!(f, "missing {what} line"),
            ParseError::BadRom(why) => write!(f, "invalid ROM hex: {why}"),
            ParseError::RomSize(n) => {
                write!(f, "ROM size {n} bytes is outside 1..=3584")
            }
            ParseError::BadCycles(s) => write!(f, "invalid cycle count {s:?}"),
            ParseError::BadEvent(s) => write!(f, "invalid key event {s:?}"),
        }
    }
}

impl std::error::Error for ParseError {}
