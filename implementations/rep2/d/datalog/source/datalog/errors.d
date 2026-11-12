/// Exception types thrown by the library.
module datalog.errors;

/// Base class of every error the library reports about a Datalog program.
class DatalogException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The program text is not well-formed.
class SyntaxException : DatalogException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// A rule violates the safety condition (see `datalog.analysis.checkSafety`).
class UnsafeRuleException : DatalogException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The program has a dependency cycle through negation.
class StratificationException : DatalogException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
