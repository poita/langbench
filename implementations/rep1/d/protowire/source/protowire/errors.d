/// Exception types thrown by the protowire library.
module protowire.errors;

/// Base class of every exception raised by this library.
class ProtowireException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The schema text could not be parsed or is inconsistent.
class SchemaException : ProtowireException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Binary data (or hex text) is malformed: truncated, over-long, bad tag, bad UTF-8, ...
class WireException : ProtowireException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Canonical text form could not be parsed against the message descriptor.
class TextException : ProtowireException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// A request line is malformed.
class RequestException : ProtowireException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
