/// Diagnostics: source positions and the compile-time error type.
module langvm.diag;

/// A 1-based line/column position. Columns count Unicode scalar values.
struct Pos
{
    int line = 1;
    int col = 1;
}

/// Every kind of compile error (SPEC.md section 13.4).
enum Kind : string
{
    badModule = "bad-module",
    dupModule = "dup-module",
    badToken = "bad-token",
    intRange = "int-range",
    badEscape = "bad-escape",
    unterminated = "unterminated",
    parse = "parse",
    reservedName = "reserved-name",
    dupName = "dup-name",
    unknownModule = "unknown-module",
    unknownType = "unknown-type",
    unknownTrait = "unknown-trait",
    notPublic = "not-public",
    arityType = "arity-type",
    badArity = "bad-arity",
    badKeyType = "bad-key-type",
    selfOutside = "self-outside",
    builtinTraitImpl = "builtin-trait-impl",
    badImplHead = "bad-impl-head",
    unusedParam = "unused-param",
    dupImpl = "dup-impl",
    missingMethod = "missing-method",
    extraMethod = "extra-method",
    sigMismatch = "sig-mismatch",
    noMain = "no-main",
    unknownName = "unknown-name",
    typeMismatch = "type-mismatch",
    arity = "arity",
    notCallable = "not-callable",
    notStruct = "not-struct",
    unknownField = "unknown-field",
    missingField = "missing-field",
    dupField = "dup-field",
    notIndexable = "not-indexable",
    notIterable = "not-iterable",
    noMethod = "no-method",
    ambigMethod = "ambig-method",
    unsatisfiedBound = "unsatisfied-bound",
    notEq = "not-eq",
    notOrd = "not-ord",
    cannotInfer = "cannot-infer",
    nonExhaustive = "non-exhaustive",
    unreachable = "unreachable",
    missingReturn = "missing-return",
    badValueRef = "bad-value-ref",
    badPattern = "bad-pattern",
    refutablePattern = "refutable-pattern",
    breakOutside = "break-outside",
    assignImmutable = "assign-immutable",
    assignCaptured = "assign-captured",
    badTarget = "bad-target",
}

/// Thrown by every compiler pass on the first error found.
class CompileError : Exception
{
    /// Which kind of error this is.
    Kind kind;
    /// Where it was found (module-local, except for the module-stream errors).
    Pos pos;

    this(Kind kind, Pos pos, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(cast(string) kind, file, line);
        this.kind = kind;
        this.pos = pos;
    }

    /// The single diagnostic line, without a trailing newline.
    string diagnostic() const @safe pure
    {
        import std.conv : to;

        return "error: " ~ cast(string) kind ~ " at " ~ pos.line.to!string ~ ":" ~ pos.col.to!string;
    }
}

/// Convenience: build a `CompileError` ready to `throw`.
CompileError err(Kind kind, Pos pos, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
{
    return new CompileError(kind, pos, file, line);
}
