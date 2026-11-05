/// Exception types used by the library.
module jq.errors;

/// A runtime error raised while evaluating a filter (what jq prints as an
/// error message). It is caught by `try`/`?` and otherwise aborts evaluation.
class JqError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// Raised for a malformed JSON document or filter text.
class ParseError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}
