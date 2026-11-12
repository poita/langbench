/**
 * Exception type thrown by every part of the library.
 */
module toml.exception;

/// Thrown when a TOML document (or a tagged-JSON document) is invalid.
class TomlException : Exception
{
    /// Byte offset into the input at which the problem was detected.
    size_t offset;
    /// One-based line number of `offset`.
    size_t line;
    /// One-based column (in bytes) of `offset`.
    size_t column;

    /// Builds an exception for the problem at byte `offset` of `source`.
    this(string msg, const(char)[] source, size_t offset,
         string file = __FILE__, size_t srcLine = __LINE__) @safe pure
    {
        import std.conv : text;

        size_t ln = 1, lineStart = 0;
        immutable end = offset < source.length ? offset : source.length;
        foreach (i; 0 .. end)
        {
            if (source[i] == '\n')
            {
                ++ln;
                lineStart = i + 1;
            }
        }
        this.offset = offset;
        this.line = ln;
        this.column = end - lineStart + 1;
        super(text("line ", line, ", column ", column, ": ", msg), file, srcLine);
    }

    /// Builds an exception that has no meaningful input position.
    this(string msg, string file = __FILE__, size_t srcLine = __LINE__) @safe pure nothrow
    {
        super(msg, file, srcLine);
    }
}
