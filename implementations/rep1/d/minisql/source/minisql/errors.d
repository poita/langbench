/**
 * Error type shared by every stage of the engine.
 *
 * A statement that fails — whether because it does not parse, refers to an
 * unknown table or column, or violates any other rule of the dialect — is
 * reported by throwing a $(LREF SqlError). The statement has no effect on the
 * database.
 */
module minisql.errors;

/// Thrown for every syntax, binding or execution error of a statement.
class SqlError : Exception
{
    /// Creates an error with a human-readable description.
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Throws a $(LREF SqlError) with `msg`.
noreturn fail(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new SqlError(msg, file, line);
}
