/**
 * Error plumbing shared by every stage of the engine.
 *
 * Every failure a build can report — a syntax error, a type error, a missing
 * input, a failing command — is a $(LREF KilnError). It carries the error
 * `kind` (for example `E_TYPE`) and the `detail` text that follows the kind on
 * the log line.
 */
module kiln.errors;

/// The single exception type for every Kiln build error.
class KilnError : Exception
{
    /// The error kind, e.g. `"E_PARSE"`.
    string kind;
    /// The detail text; empty for kinds that have none.
    string detail;
    /// Whether the kind has a detail (`E_NO_DEFAULT` and `E_DIV_ZERO` do not).
    bool hasDetail;

    ///
    this(string kind, string detail, bool hasDetail = true,
            string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(kind, file, line);
        this.kind = kind;
        this.detail = detail;
        this.hasDetail = hasDetail;
    }

    /// The text of the log's `error` line without its leading indentation.
    string render() const @safe pure nothrow
    {
        return hasDetail ? kind ~ " " ~ detail : kind;
    }
}

/// Throws a `KilnError` whose detail is `detail`.
noreturn fail(string kind, string detail, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new KilnError(kind, detail, true, file, line);
}

/// Throws a `KilnError` that has no detail.
noreturn failBare(string kind, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new KilnError(kind, "", false, file, line);
}

/// Throws `E_PARSE <file>:<line>`.
noreturn failParse(string file, int line) @safe pure
{
    import std.conv : to;

    throw new KilnError("E_PARSE", file ~ ":" ~ line.to!string);
}

/// Builds the `E_TYPE <site>: expected <expected>, got <actual>` error.
noreturn failType(string site, string expected, string actual) @safe pure
{
    throw new KilnError("E_TYPE", site ~ ": expected " ~ expected ~ ", got " ~ actual);
}

@safe pure unittest
{
    auto e = new KilnError("E_TYPE", "operator +: expected int, got str");
    assert(e.render == "E_TYPE operator +: expected int, got str");
    auto b = new KilnError("E_NO_DEFAULT", "", false);
    assert(b.render == "E_NO_DEFAULT");
}
