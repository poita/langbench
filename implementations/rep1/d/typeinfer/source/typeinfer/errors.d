/**
 * Error types shared by the whole library.
 *
 * Type errors are reported as an `ErrorKind`; malformed programs (which the
 * specification does not require handling) raise a `SyntaxError`.
 */
module typeinfer.errors;

/// Why a declaration failed to type-check.
enum ErrorKind : ubyte
{
    /// No error: the declaration type-checked.
    none,
    /// A variable is not in scope.
    unbound,
    /// Unification would build an infinite type.
    occurs,
    /// Any other unification failure (constructor or arity mismatch).
    unify,
}

/// The word used for `kind` in the program's output (`"unify"`, ...).
string toText(ErrorKind kind) pure nothrow @safe @nogc
{
    final switch (kind)
    {
    case ErrorKind.none:    return "none";
    case ErrorKind.unbound: return "unbound";
    case ErrorKind.occurs:  return "occurs";
    case ErrorKind.unify:   return "unify";
    }
}

/// Thrown internally to abort inference of one declaration.
class TypeError : Exception
{
    /// The kind of failure.
    ErrorKind kind;

    ///
    this(ErrorKind kind, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(toText(kind), file, line);
        this.kind = kind;
    }
}

/// Thrown by the lexer and parser on malformed input.
class SyntaxError : Exception
{
    /// Byte offset in the source (or the source length for "unexpected end").
    size_t offset;

    ///
    this(string message, size_t offset, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(message, file, line);
        this.offset = offset;
    }
}
