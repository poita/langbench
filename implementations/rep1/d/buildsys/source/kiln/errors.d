/// Error type shared by every stage of a Kiln build.
module kiln.errors;

/// A Kiln build error: a kind such as `E_TYPE` and an optional detail text.
///
/// Rendering with `render` gives the text that follows `error ` in a log line.
class KilnError : Exception
{
    /// The error kind, e.g. `E_UNKNOWN_VAR`.
    string kind;
    /// The detail text; empty for kinds that have none.
    string detail;

    ///
    this(string kind, string detail = "", string file = __FILE__, size_t line = __LINE__) @safe
    {
        this.kind = kind;
        this.detail = detail;
        super(detail.length ? kind ~ " " ~ detail : kind, file, line);
    }

    /// The kind, followed by a space and the detail when there is one.
    string render() const @safe
    {
        return detail.length ? kind ~ " " ~ detail : kind;
    }
}

/// `E_PARSE <file>:<line>`
KilnError parseError(string file, int line) @safe
{
    import std.conv : to;

    return new KilnError("E_PARSE", file ~ ":" ~ line.to!string);
}

/// `E_TYPE <site>: expected <expected>, got <actual>`
KilnError typeError(string site, string expected, string actual) @safe
{
    return new KilnError("E_TYPE", site ~ ": expected " ~ expected ~ ", got " ~ actual);
}

/// `E_ARG <kind> <name>: <reason>`
KilnError argError(string kind, string name, string reason) @safe
{
    return new KilnError("E_ARG", kind ~ " " ~ name ~ ": " ~ reason);
}
