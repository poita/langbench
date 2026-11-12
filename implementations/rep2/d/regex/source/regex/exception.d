/**
 * Exception types thrown by the library.
 */
module regex.exception;

/// Thrown when a pattern is syntactically invalid or too large to compile.
class RegexException : Exception
{
    /// Offset in the pattern at which the problem was detected.
    size_t position;

    this(string msg, size_t position = 0, string file = __FILE__, size_t line = __LINE__)
        pure nothrow @safe
    {
        super(msg, file, line);
        this.position = position;
    }
}
