/// Error type shared by every stage of the engine.
module minisql.errors;

/// Thrown when a statement is rejected: a syntax error, an unknown table or
/// column, an arity mismatch, and so on. A statement that throws has had no
/// effect on the database.
class SqlException : Exception
{
    /// Creates an exception carrying a human-readable description.
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Throws a `SqlException` with the given message.
noreturn fail(string msg, string file = __FILE__, size_t line = __LINE__) pure @safe
{
    throw new SqlException(msg, file, line);
}
