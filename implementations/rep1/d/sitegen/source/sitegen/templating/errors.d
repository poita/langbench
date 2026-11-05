/// Error type of the template engine.
module sitegen.templating.errors;

/// The five failure classes of the template language.
enum ErrorKind
{
    syntax, /// unlexable or unparsable template
    filter, /// unknown filter name
    undefined, /// forbidden use of the undefined value
    template_, /// include/extends of a template that does not exist
    type, /// operand or argument of the wrong kind
}

/// Thrown for any template failure.
class TemplateError : Exception
{
    /// What went wrong.
    ErrorKind kind;

    this(ErrorKind kind, string detail = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        this.kind = kind;
        super(detail.length ? detail : kindName(kind), file, line);
    }

    /// The short name of the error kind (`syntax`, `filter`, ...).
    static string kindName(ErrorKind k) pure nothrow @safe @nogc
    {
        final switch (k)
        {
        case ErrorKind.syntax: return "syntax";
        case ErrorKind.filter: return "filter";
        case ErrorKind.undefined: return "undefined";
        case ErrorKind.template_: return "template";
        case ErrorKind.type: return "type";
        }
    }
}

package TemplateError syntaxError(string detail = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
{
    return new TemplateError(ErrorKind.syntax, detail, file, line);
}

package TemplateError typeError(string detail = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
{
    return new TemplateError(ErrorKind.type, detail, file, line);
}

package TemplateError undefinedError(string detail = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
{
    return new TemplateError(ErrorKind.undefined, detail, file, line);
}
