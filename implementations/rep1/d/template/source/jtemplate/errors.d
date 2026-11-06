/// Error type shared by every stage of the engine.
module jtemplate.errors;

/// The five failure categories defined by the specification.
enum ErrorKind : ubyte
{
    /// The template could not be lexed or parsed.
    syntax,
    /// A loaded template uses an unknown filter name.
    filter,
    /// The undefined value was used in a forbidden way.
    undefined,
    /// An `include` / `extends` named a template that does not exist.
    missingTemplate,
    /// An operand, argument or call had the wrong kind.
    type,
}

/// The short lower-case name of an error kind (`"syntax"`, `"template"`, ...).
string name(ErrorKind kind) pure nothrow @safe @nogc
{
    final switch (kind)
    {
        case ErrorKind.syntax:          return "syntax";
        case ErrorKind.filter:          return "filter";
        case ErrorKind.undefined:       return "undefined";
        case ErrorKind.missingTemplate: return "template";
        case ErrorKind.type:            return "type";
    }
}

/// Exception thrown for every template error; `kind` says which one.
class TemplateError : Exception
{
    /// What went wrong.
    ErrorKind kind;

    ///
    this(ErrorKind kind, string detail = null, string file = __FILE__, size_t line = __LINE__)
        pure nothrow @safe
    {
        this.kind = kind;
        super(detail.length ? name(kind) ~ ": " ~ detail : name(kind), file, line);
    }
}

/// Convenience constructors, used as `throw syntaxError("...")`.
TemplateError syntaxError(string detail = null, string file = __FILE__, size_t line = __LINE__)
    pure nothrow @safe
{
    return new TemplateError(ErrorKind.syntax, detail, file, line);
}

/// ditto
TemplateError filterError(string detail = null, string file = __FILE__, size_t line = __LINE__)
    pure nothrow @safe
{
    return new TemplateError(ErrorKind.filter, detail, file, line);
}

/// ditto
TemplateError undefinedError(string detail = null, string file = __FILE__, size_t line = __LINE__)
    pure nothrow @safe
{
    return new TemplateError(ErrorKind.undefined, detail, file, line);
}

/// ditto
TemplateError missingTemplateError(string detail = null, string file = __FILE__, size_t line = __LINE__)
    pure nothrow @safe
{
    return new TemplateError(ErrorKind.missingTemplate, detail, file, line);
}

/// ditto
TemplateError typeError(string detail = null, string file = __FILE__, size_t line = __LINE__)
    pure nothrow @safe
{
    return new TemplateError(ErrorKind.type, detail, file, line);
}
