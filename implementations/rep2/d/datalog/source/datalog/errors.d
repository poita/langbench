/// Exception types thrown by the library.
module datalog.errors;

/// Base class of every exception thrown by this library.
class DatalogException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The program text is not syntactically well-formed.
class ParseException : DatalogException
{
    /// Byte offset in the source at which the problem was detected.
    size_t offset;

    ///
    this(string msg, size_t offset, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.offset = offset;
    }
}

/// The program is well-formed but is either unsafe or not stratifiable, so it has no
/// stratified model.
class ProgramError : DatalogException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
