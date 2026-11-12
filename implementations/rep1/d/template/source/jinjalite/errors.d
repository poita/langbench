/// Error types shared by every stage of the engine.
module jinjalite.errors;

/// The five failure categories a template or its rendering can end in.
enum ErrorKind : ubyte
{
    /// The template cannot be lexed or parsed.
    syntax,
    /// A loaded template uses an unknown filter name.
    filter,
    /// The undefined value was used in a forbidden way.
    undefined,
    /// An `include` or `extends` names a template that does not exist.
    missingTemplate,
    /// An operand, argument or call had the wrong kind or count.
    type,
}

/// The short name of an error kind, as printed by the command-line tool.
string kindName(ErrorKind kind) @safe pure nothrow @nogc
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

/// Thrown for every error that is part of the template language.
class TemplateError : Exception
{
    /// The category of this error.
    ErrorKind kind;

    ///
    this(ErrorKind kind, string message, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(message, file, line);
        this.kind = kind;
    }
}

/// Throw a `TemplateError` of kind `ErrorKind.syntax`.
noreturn syntaxError(string message, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new TemplateError(ErrorKind.syntax, message, file, line);
}

/// Throw a `TemplateError` of kind `ErrorKind.type`.
noreturn typeError(string message, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new TemplateError(ErrorKind.type, message, file, line);
}

/// Throw a `TemplateError` of kind `ErrorKind.undefined`.
noreturn undefinedError(string message, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new TemplateError(ErrorKind.undefined, message, file, line);
}

@safe pure unittest
{
    assert(kindName(ErrorKind.missingTemplate) == "template");
    try
        syntaxError("boom");
    catch (TemplateError e)
    {
        assert(e.kind == ErrorKind.syntax);
        assert(e.msg == "boom");
    }
}
