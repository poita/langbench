/// Diagnostics: the single error a malformed input is reported as.
module typeset.errors;

import std.format : format;

/// Where and why an input was rejected. `line`/`col` are 1-based; the column
/// counts Unicode scalar values.
struct Diagnostic
{
    string file; /// `settings.cfg`, `document.cdx` or `-`
    int line;
    int col;
    string code; /// e.g. `bad-length`

    /// The `error.txt` line (without the trailing newline).
    string toString() const @safe
    {
        return format("%s:%d:%d: %s", file, line, col, code);
    }
}

/// Thrown by the parsers on the first error found.
class TypesetError : Exception
{
    Diagnostic diagnostic;

    this(Diagnostic d, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(d.code, file, line);
        diagnostic = d;
    }
}

/// Throws a `TypesetError`.
noreturn fail(string file, int line, int col, string code) @safe pure
{
    throw new TypesetError(Diagnostic(file, line, col, code));
}

@safe unittest
{
    assert(Diagnostic("settings.cfg", 2, 15, "bad-length").toString == "settings.cfg:2:15: bad-length");
}
