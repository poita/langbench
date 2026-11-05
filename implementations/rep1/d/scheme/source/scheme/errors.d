/// Runtime errors raised by Scheme programs.
module scheme.errors;

/// The categories of runtime error defined by the language.
enum ErrorKind : string
{
    unboundVariable = "unbound-variable",
    typeError = "type-error",
    arityError = "arity-error",
    divisionByZero = "division-by-zero",
    userError = "user-error",
}

/// Thrown when a Scheme program hits a runtime error. `msg` is the category
/// name as printed after `error: `.
class SchemeError : Exception
{
    /// The error category.
    ErrorKind kind;

    this(ErrorKind kind) @safe pure nothrow
    {
        super(cast(string) kind);
        this.kind = kind;
    }
}

/// Throw a `SchemeError` of the given kind.
noreturn raise(ErrorKind kind)
{
    throw new SchemeError(kind);
}

/// Shorthands for the common categories.
noreturn typeError() { raise(ErrorKind.typeError); }
/// ditto
noreturn arityError() { raise(ErrorKind.arityError); }
/// ditto
noreturn unboundVariable() { raise(ErrorKind.unboundVariable); }
