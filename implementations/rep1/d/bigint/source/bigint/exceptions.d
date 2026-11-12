/// Exception types thrown by the library.
module bigint.exceptions;

/// Base class of all exceptions thrown by this library.
class BigIntException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// Thrown by `/` and `%` when the divisor is zero.
class DivisionByZeroException : BigIntException
{
    ///
    this(string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super("division by zero", file, line);
    }
}

/// Thrown by `pow` when the exponent is negative.
class NegativeExponentException : BigIntException
{
    ///
    this(string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super("negative exponent", file, line);
    }
}

/// Thrown by `pow` when the exponent is too large to compute (|base| > 1).
class ExponentTooLargeException : BigIntException
{
    ///
    this(string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super("exponent too large", file, line);
    }
}

/// Thrown when a string is not a valid decimal integer.
class ParseException : BigIntException
{
    ///
    this(string msg = "invalid decimal integer", string file = __FILE__,
            size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
