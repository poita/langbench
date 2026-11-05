/// Exception type thrown by the engine.
module regex.exception;

/// Thrown when a pattern is not valid according to the supported syntax.
class RegexException : Exception
{
    /// Offset in the pattern at which the problem was detected.
    size_t offset;

    ///
    this(string msg, size_t offset = 0, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.offset = offset;
    }
}
