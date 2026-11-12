/**
 * Error types shared by every stage of Kiln.
 *
 * A build fails with exactly one `KilnError`, which carries the error *kind*
 * (`E_PARSE`, `E_TYPE`, ...) and a free-form *detail* string.  The text that is
 * written to the session log is `kind` followed by a space and `detail`.
 */
module kiln.errors;

/// A build error: one of the thirty documented kinds plus its detail text.
class KilnError : Exception
{
    /// The error kind, e.g. `"E_CYCLE"`.
    string kind;
    /// The detail text; empty for kinds that have none.
    string detail;

    ///
    this(string kind, string detail = "", string file = __FILE__, size_t line = __LINE__)
        @safe pure nothrow
    {
        this.kind = kind;
        this.detail = detail;
        super(detail.length ? kind ~ " " ~ detail : kind, file, line);
    }
}

/// Internal lexical/grammar failure; converted to `E_PARSE` with a file and line.
class SyntaxError : Exception
{
    /// 1-based number of the first physical line of the offending logical line.
    int line;

    ///
    this(int line = 0, string msg = "syntax error", string file = __FILE__, size_t srcLine = __LINE__)
        @safe pure nothrow
    {
        this.line = line;
        super(msg, file, srcLine);
    }
}

/// Builds the `E_TYPE` error for `site`.
KilnError typeError(string site, string expected, string actual) @safe pure nothrow
{
    return new KilnError("E_TYPE", site ~ ": expected " ~ expected ~ ", got " ~ actual);
}

unittest
{
    auto e = new KilnError("E_NO_DEFAULT");
    assert(e.msg == "E_NO_DEFAULT");
    auto t = typeError("operator +", "int", "str");
    assert(t.msg == "E_TYPE operator +: expected int, got str");
    assert(t.kind == "E_TYPE");
}
