/// Error reporting for the DEFLATE decoder.
module inflate.error;

/// The reason a stream was rejected.
enum InflateError
{
    /// The stream ended before the final block was complete.
    truncated,
    /// A block header had `BTYPE == 3`.
    invalidBlockType,
    /// A stored block's `LEN` and `NLEN` were not one's complements.
    storedLengthMismatch,
    /// `HLIT > 29` or `HDIST > 29`.
    tooManyCodes,
    /// A set of code lengths was over-subscribed.
    oversubscribedCode,
    /// A set of code lengths was incomplete (and not an allowed exception).
    incompleteCode,
    /// The literal/length code gave symbol 256 no code.
    missingEndOfBlock,
    /// Code-length symbol 16 appeared with no previous length.
    repeatWithoutPrevious,
    /// A code-length repeat overflowed the number of lengths.
    repeatOverflow,
    /// A bit pattern matched no code of an incomplete table.
    invalidCode,
    /// Literal/length symbol 286/287 or distance symbol 30/31.
    invalidSymbol,
    /// A distance code was needed but the distance code set is empty.
    noDistanceCodes,
    /// A back-reference reached before the start of the output.
    distanceTooFar,
    /// Whole bytes remained after the final block.
    trailingData,
    /// The output exceeded the caller-supplied limit.
    outputLimitExceeded,
    /// A hex string had an invalid digit or odd length.
    invalidHex,
}

/// Thrown when a stream is malformed.
class InflateException : Exception
{
    /// What went wrong.
    InflateError kind;

    ///
    this(InflateError kind, string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.kind = kind;
    }
}

/// Throw an `InflateException` of the given kind.
package noreturn fail(InflateError kind, string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new InflateException(kind, msg, file, line);
}
