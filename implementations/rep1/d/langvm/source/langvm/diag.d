/// Diagnostics (compile errors) and run-time panics.
module langvm.diag;

/// A source position: 1-based line and column (columns count Unicode scalar values).
struct Pos
{
    int line = 1;
    int col = 1;
}

/// A compile-time diagnostic: `error: <kind> at <line>:<col>`.
class CompileError : Exception
{
    /// One of the diagnostic kinds of the language specification (e.g. `type-mismatch`).
    string kind;
    /// Line of the error (module-local except for module-stream errors).
    int line;
    /// Column of the error.
    int col;

    this(string kind, int line, int col, string file = __FILE__, size_t ln = __LINE__)
    {
        import std.conv : to;

        super("error: " ~ kind ~ " at " ~ line.to!string ~ ":" ~ col.to!string, file, ln);
        this.kind = kind;
        this.line = line;
        this.col = col;
    }

    this(string kind, Pos p, string file = __FILE__, size_t ln = __LINE__)
    {
        this(kind, p.line, p.col, file, ln);
    }
}

/// Throws a [CompileError] of the given kind at the given position.
noreturn fail(string kind, Pos p, string file = __FILE__, size_t ln = __LINE__)
{
    throw new CompileError(kind, p.line, p.col, file, ln);
}

/// A run-time panic of the executing Vellum program (the message follows `panic: `).
class Panic : Exception
{
    this(string msg, string file = __FILE__, size_t ln = __LINE__)
    {
        super(msg, file, ln);
    }
}

/// Throws a [Panic].
noreturn panic(string msg, string file = __FILE__, size_t ln = __LINE__)
{
    throw new Panic(msg, file, ln);
}
