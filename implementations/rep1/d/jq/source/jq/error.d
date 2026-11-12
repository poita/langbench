/// Exception types raised by the library.
module jq.error;

/// Base class of every exception thrown by this library.
class JqException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// A runtime error raised while a filter is evaluated (the jq "error" condition).
/// `?` and `try` catch exactly this class.
class JqError : JqException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The filter text is not syntactically valid.
class JqSyntaxError : JqException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The JSON text is not valid.
class JsonParseError : JqException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
