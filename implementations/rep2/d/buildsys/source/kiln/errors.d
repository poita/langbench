/**
 * Error plumbing shared by every stage of Kiln.
 *
 * Every failure that a build can report is a $(LREF KilnError) carrying the
 * error *kind* (for example `E_TYPE`) and a *detail* string. The log line
 * for a failed build is `error <kind> <detail>`.
 */
module kiln.errors;

/// The exception thrown for every error described by the specification.
class KilnError : Exception
{
    /// The error kind, such as `E_PARSE` or `E_CYCLE`.
    string kind;
    /// The kind-specific detail; empty for kinds that have none.
    string detail;

    ///
    this(string kind, string detail = "", string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(detail.length ? kind ~ " " ~ detail : kind, file, line);
        this.kind = kind;
        this.detail = detail;
    }

    /// The text that follows `error ` on a log line.
    string render() const @safe pure nothrow
    {
        return detail.length ? kind ~ " " ~ detail : kind;
    }
}

/// `E_PARSE <file>:<line>`
KilnError parseError(string file, int line) @safe pure
{
    import std.conv : to;

    return new KilnError("E_PARSE", file ~ ":" ~ line.to!string);
}

/// `E_TYPE <site>: expected <expected>, got <actual>`
KilnError typeError(string site, string expected, string actual) @safe pure
{
    return new KilnError("E_TYPE", site ~ ": expected " ~ expected ~ ", got " ~ actual);
}

/// `E_ARG <kind> <name>: <reason>`
KilnError argError(string kind, string name, string reason) @safe pure
{
    return new KilnError("E_ARG", kind ~ " " ~ name ~ ": " ~ reason);
}

/// `E_ARITY <kind> <name>: expected <expected>, got <got>`
KilnError arityError(string kind, string name, string expected, size_t got) @safe pure
{
    import std.conv : to;

    return new KilnError("E_ARITY", kind ~ " " ~ name ~ ": expected " ~ expected ~ ", got " ~ got.to!string);
}
