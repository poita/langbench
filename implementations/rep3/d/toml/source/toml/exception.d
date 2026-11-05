/// Exception type shared by all modules of the library.
module toml.exception;

/// Thrown when a TOML document (or tagged JSON text) is invalid.
class TomlException : Exception
{
    /// Byte offset into the input at which the problem was detected.
    size_t offset;

    ///
    this(string msg, size_t offset = 0, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
        this.offset = offset;
    }
}
