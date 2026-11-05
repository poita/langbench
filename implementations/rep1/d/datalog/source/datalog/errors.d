/// Exception types thrown by the library.
module datalog.errors;

/// Base class of every exception thrown by this library.
class DatalogException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// The program text is not well formed (bad token or unexpected token).
class ParseException : DatalogException
{
    /// 1-based line number at which the problem was detected.
    size_t sourceLine;

    this(string msg, size_t sourceLine, string file = __FILE__, size_t line = __LINE__) @safe
    {
        import std.conv : to;

        super("line " ~ sourceLine.to!string ~ ": " ~ msg, file, line);
        this.sourceLine = sourceLine;
    }
}

/// A rule violates the safety condition (a variable is not bound by a positive body atom).
class UnsafeRuleException : DatalogException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// The predicate dependency graph has a cycle through a negative edge.
class StratificationException : DatalogException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}
