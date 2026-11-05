/// Exception types thrown by the library.
module toml.errors;

/// Thrown when a TOML document is not valid TOML 1.0.0.
class TomlException : Exception
{
    /// Byte offset into the document at which the problem was detected.
    size_t offset;

    ///
    this(string msg, size_t offset = 0, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.offset = offset;
    }
}
