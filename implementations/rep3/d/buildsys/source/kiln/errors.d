/// Error type shared by every stage of a Kiln build.
module kiln.errors;

/// A Kiln error: one of the thirty documented kinds plus an optional detail.
///
/// Configuration errors (everything but the `E_NEED_*` kinds) abort a build
/// before it executes; the `E_NEED_*` kinds are raised by `preprocess` at
/// execution time.
class KilnError : Exception
{
    /// The error kind, e.g. `E_TYPE`.
    string kind;
    /// The detail text (empty when `hasDetail` is false).
    string detail;
    /// Whether the kind carries a detail at all.
    bool hasDetail;

    /// An error with no detail (`E_NO_DEFAULT`, `E_DIV_ZERO`).
    this(string kind) @safe pure nothrow
    {
        super(kind);
        this.kind = kind;
    }

    /// An error with a detail.
    this(string kind, string detail) @safe pure nothrow
    {
        super(kind ~ " " ~ detail);
        this.kind = kind;
        this.detail = detail;
        this.hasDetail = true;
    }

    /// The text that follows `error ` on a log line: `KIND` or `KIND detail`.
    string render() const @safe pure nothrow
    {
        return hasDetail ? kind ~ " " ~ detail : kind;
    }
}

/// A syntax problem inside a token stream or string literal. The lexer and
/// parser convert it into `E_PARSE <file>:<line>` once the line is known.
class SyntaxFail : Exception
{
    this(string msg = "syntax error", string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Build an `E_PARSE` error.
KilnError parseError(string file, int line) @safe
{
    import std.conv : to;
    return new KilnError("E_PARSE", file ~ ":" ~ line.to!string);
}

/// Build an `E_TYPE` error.
KilnError typeError(string site, string expected, string actual) @safe
{
    return new KilnError("E_TYPE", site ~ ": expected " ~ expected ~ ", got " ~ actual);
}

/// Build an `E_ARG` error (`E_ARG <kind> <name>: <reason>`).
KilnError argError(string kind, string name, string reason) @safe
{
    return new KilnError("E_ARG", kind ~ " " ~ name ~ ": " ~ reason);
}
