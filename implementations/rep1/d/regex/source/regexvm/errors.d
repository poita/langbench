/// Exception types thrown by the regexvm library.
module regexvm.errors;

/// Thrown when a pattern is syntactically invalid or too large to compile.
class RegexException : Exception
{
    /// Offset into the pattern at which the problem was detected
    /// (`size_t.max` when not applicable).
    size_t offset = size_t.max;

    ///
    this(string msg, size_t offset = size_t.max,
         string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

/// Thrown by the batch driver when its input does not follow the
/// documented line format.
class InputFormatException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}
