/// Exception type used by the library.
module rrule.errors;

/// Thrown when a rule, date-time or input line is malformed.
class RRuleException : Exception
{
    /// Creates an exception with the given message.
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}
