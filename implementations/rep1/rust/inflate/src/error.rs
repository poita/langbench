//! Error type returned by the decoder.

use std::fmt;

/// Everything that can make a DEFLATE stream malformed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// The stream ended before the final block was complete.
    UnexpectedEof,
    /// A block header had `BTYPE = 3`.
    InvalidBlockType,
    /// A stored block's `NLEN` is not the one's complement of `LEN`.
    StoredLengthMismatch,
    /// `HLIT > 29` or `HDIST > 29`.
    TooManyCodes,
    /// A set of code lengths is over-subscribed.
    OverSubscribedCode,
    /// A set of code lengths is incomplete in a way that is not permitted.
    IncompleteCode,
    /// The literal/length code gives the end-of-block symbol no code.
    MissingEndOfBlock,
    /// Code-length symbol 16 appeared with no previous length.
    RepeatWithoutPrevious,
    /// A code-length repeat ran past the declared number of lengths.
    RepeatOverflow,
    /// The bits read do not correspond to any code of an incomplete table.
    InvalidCode,
    /// Literal/length symbol 286 or 287, or distance symbol 30 or 31.
    InvalidSymbol,
    /// A length code was decoded but the distance code set is empty.
    NoDistanceCodes,
    /// A back-reference reaches before the start of the output.
    DistanceTooFar,
    /// Whole bytes remain after the final block.
    TrailingData,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let msg = match self {
            Error::UnexpectedEof => "stream ended before the final block was complete",
            Error::InvalidBlockType => "invalid block type 3",
            Error::StoredLengthMismatch => "stored block LEN/NLEN mismatch",
            Error::TooManyCodes => "too many literal/length or distance codes",
            Error::OverSubscribedCode => "over-subscribed Huffman code",
            Error::IncompleteCode => "incomplete Huffman code",
            Error::MissingEndOfBlock => "no code for the end-of-block symbol",
            Error::RepeatWithoutPrevious => "code length repeat with no previous length",
            Error::RepeatOverflow => "code length repeat overflows the length table",
            Error::InvalidCode => "bit pattern is not a valid Huffman code",
            Error::InvalidSymbol => "reserved literal/length or distance symbol",
            Error::NoDistanceCodes => "length code with an empty distance code",
            Error::DistanceTooFar => "distance exceeds the output produced so far",
            Error::TrailingData => "trailing data after the final block",
        };
        f.write_str(msg)
    }
}

impl std::error::Error for Error {}

/// Convenience alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;
