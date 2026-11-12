/// Exception types thrown by the library.
module datalog.errors;

/// Base class of every error the library reports about a program.
class DatalogException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The program text is not syntactically valid.
class ParseException : DatalogException
{
    /// 1-based line of the offending token.
    size_t sourceLine;

    this(string msg, size_t sourceLine, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
        this.sourceLine = sourceLine;
    }
}

/// A rule is not safe (a variable is not bound by a positive body atom).
class UnsafeRuleException : DatalogException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// A cycle of the predicate dependency graph contains a negative edge.
class StratificationException : DatalogException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
