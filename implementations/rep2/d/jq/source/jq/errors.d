/// Exception types raised by the JSON parser, the filter parser and the interpreter.
module jq.errors;

import jq.value : Value;

/// Runtime error raised while evaluating a filter (type errors, `error`, ...).
///
/// `payload` is the value carried by `error(f)` (or the input for plain
/// `error`); for built-in failures it is a string holding the message.
class JqError : Exception
{
    Value payload;

    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
        payload = Value.fromString(msg);
    }

    this(Value payload, string msg = "jq error", string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(msg, file, line);
        this.payload = payload;
    }
}

/// Raised when a JSON document is malformed.
class JsonException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Raised when a filter program cannot be parsed.
class FilterSyntaxError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
