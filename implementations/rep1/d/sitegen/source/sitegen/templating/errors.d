/**
 * Error reporting for the template engine.
 */
module sitegen.templating.errors;

/// The kinds of template error.
enum ErrorKind : ubyte
{
    /// The template cannot be lexed or parsed.
    syntax,
    /// A loaded template uses an unknown filter.
    filter,
    /// The undefined value was used in a way that is not allowed.
    undefined,
    /// An `include` or `extends` names a template that does not exist.
    template_,
    /// An operand or argument has the wrong kind, or an operation is invalid.
    type,
}

/// The exception thrown for every template error.
class TemplateException : Exception
{
    /// What went wrong.
    ErrorKind kind;

    ///
    this(ErrorKind kind, string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
        this.kind = kind;
    }
}

/// Throws a `syntax` error.
noreturn syntaxError(string message, string file = __FILE__, size_t line = __LINE__)
{
    throw new TemplateException(ErrorKind.syntax, message, file, line);
}

/// Throws a `filter` error.
noreturn filterError(string message, string file = __FILE__, size_t line = __LINE__)
{
    throw new TemplateException(ErrorKind.filter, message, file, line);
}

/// Throws an `undefined` error.
noreturn undefinedError(string message, string file = __FILE__, size_t line = __LINE__)
{
    throw new TemplateException(ErrorKind.undefined, message, file, line);
}

/// Throws a `template` error.
noreturn templateError(string message, string file = __FILE__, size_t line = __LINE__)
{
    throw new TemplateException(ErrorKind.template_, message, file, line);
}

/// Throws a `type` error.
noreturn typeError(string message, string file = __FILE__, size_t line = __LINE__)
{
    throw new TemplateException(ErrorKind.type, message, file, line);
}
