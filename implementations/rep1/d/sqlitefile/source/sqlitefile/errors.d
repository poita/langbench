/// Exception types thrown by the library.
module sqlitefile.errors;

@safe:

/// Base class of every exception thrown by this library.
class SqliteFileException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc
    {
        super(msg, file, line);
    }
}

/// The database file is malformed (truncated, bad page number, corrupt cell…).
class FormatException : SqliteFileException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc
    {
        super(msg, file, line);
    }
}

/// A `CREATE TABLE` / `CREATE INDEX` statement could not be understood.
class SchemaException : SqliteFileException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc
    {
        super(msg, file, line);
    }
}

/// A query is malformed or refers to something that does not exist.
class QueryException : SqliteFileException
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc
    {
        super(msg, file, line);
    }
}
