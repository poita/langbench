/// Error reporting for the DEFLATE decoder.
module inflate.errors;

/// Every way a DEFLATE stream can be malformed.
enum InflateError
{
    /// The stream ended before the final block was complete.
    truncated,
    /// A block header used the reserved block type 3.
    invalidBlockType,
    /// A stored block's NLEN is not the complement of LEN.
    storedLengthMismatch,
    /// HLIT > 29 or HDIST > 29.
    tooManyCodes,
    /// A Huffman code length set is over-subscribed.
    overSubscribedCode,
    /// A Huffman code length set is incomplete (beyond the permitted exceptions).
    incompleteCode,
    /// The literal/length code gives the end-of-block symbol no code.
    missingEndOfBlock,
    /// Code-length symbol 16 appeared with no previous length.
    repeatWithoutPrevious,
    /// A code-length repeat ran past the declared number of lengths.
    repeatOverflow,
    /// A bit pattern that is not a code of an incomplete table was read.
    invalidCode,
    /// Literal/length symbol 286/287 or distance symbol 30/31 was decoded.
    invalidSymbol,
    /// A distance reached back before the start of the output.
    distanceTooFar,
    /// Whole bytes remain after the final block.
    trailingData,
}

/// Human-readable description of an `InflateError`.
string describe(InflateError e) pure nothrow @nogc @safe
{
    final switch (e)
    {
    case InflateError.truncated:             return "unexpected end of stream";
    case InflateError.invalidBlockType:      return "invalid block type 3";
    case InflateError.storedLengthMismatch:  return "stored block LEN/NLEN mismatch";
    case InflateError.tooManyCodes:          return "too many literal/length or distance codes";
    case InflateError.overSubscribedCode:    return "over-subscribed Huffman code";
    case InflateError.incompleteCode:        return "incomplete Huffman code";
    case InflateError.missingEndOfBlock:     return "no code for end-of-block symbol";
    case InflateError.repeatWithoutPrevious: return "length repeat with no previous length";
    case InflateError.repeatOverflow:        return "length repeat overflows the code length list";
    case InflateError.invalidCode:           return "bit pattern is not a valid Huffman code";
    case InflateError.invalidSymbol:         return "invalid literal/length or distance symbol";
    case InflateError.distanceTooFar:        return "distance too far back";
    case InflateError.trailingData:          return "trailing data after final block";
    }
}

/// Thrown by the decoder when the stream is malformed.
class InflateException : Exception
{
    /// What went wrong.
    InflateError error;

    ///
    this(InflateError error, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(describe(error), file, line);
        this.error = error;
    }
}
