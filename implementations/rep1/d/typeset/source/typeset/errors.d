/// Diagnostics: the error codes of the specification and the exception that
/// carries the first one found.
module typeset.errors;

/// Every error code the engine can report.
enum ErrorCode
{
    missingDocument,
    badSyntax,
    unknownSetting,
    duplicateSetting,
    badLength,
    badInteger,
    badBoolean,
    badEnum,
    unknownFont,
    unknownPatterns,
    badValue,
    badEscape,
    unknownPlaceholder,
    strayBrace,
    unknownBlock,
    blockNotAllowed,
    duplicateToc,
    unexpectedEnd,
    missingEnd,
    badAttribute,
    missingAttribute,
    badAttributeValue,
    cellCount,
    textNotAllowed,
    unknownMeta,
    duplicateMeta,
    unknownInline,
    unclosedInline,
    nestedFootnote,
    footnoteNotAllowed,
}

private immutable string[] codeNames = [
    "missing-document", "bad-syntax", "unknown-setting", "duplicate-setting",
    "bad-length", "bad-integer", "bad-boolean", "bad-enum", "unknown-font",
    "unknown-patterns", "bad-value", "bad-escape", "unknown-placeholder",
    "stray-brace", "unknown-block", "block-not-allowed", "duplicate-toc",
    "unexpected-end", "missing-end", "bad-attribute", "missing-attribute",
    "bad-attribute-value", "cell-count", "text-not-allowed", "unknown-meta",
    "duplicate-meta", "unknown-inline", "unclosed-inline", "nested-footnote",
    "footnote-not-allowed",
];

/// The kebab-case name of an error code, as written in `error.txt`.
string codeName(ErrorCode c) pure nothrow @nogc @safe
{
    return codeNames[c];
}

/// One located error.
struct Diagnostic
{
    string file; /// `settings.cfg`, `document.cdx` or `-`
    int line; /// 1-based line (0 for `missing-document`)
    int col; /// 1-based column in Unicode scalar values
    ErrorCode code;

    /// `file:line:col: code`
    string toString() const @safe
    {
        import std.conv : to;

        return file ~ ":" ~ line.to!string ~ ":" ~ col.to!string ~ ": " ~ codeName(code);
    }
}

/// Thrown by the parsers on the first invalid construct.
class TypesetError : Exception
{
    Diagnostic diag; ///

    this(Diagnostic d, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(d.toString(), file, line);
        diag = d;
    }
}

/// Throws a `TypesetError`.
noreturn fail(string file, int line, int col, ErrorCode code) @safe
{
    throw new TypesetError(Diagnostic(file, line, col, code));
}
