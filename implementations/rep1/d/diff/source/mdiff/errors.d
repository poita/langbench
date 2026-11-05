/// Exception types thrown by the mdiff library.
module mdiff.errors;

/// Base class of every error mdiff reports.
class MdiffException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The textual input (mode line, counts, line blocks) is malformed.
class FormatException : MdiffException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// An edit script is not valid for the file it is applied to.
class PatchException : MdiffException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
