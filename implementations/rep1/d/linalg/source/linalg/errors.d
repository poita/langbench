/**
 * Error taxonomy shared by every operation in the library.
 *
 * Each failure is reported as a `LinAlgException` carrying an `ErrorCode`;
 * the command-line driver writes the code's name to `NNN_error.txt`.
 */
module linalg.errors;

/// The reasons an operation can refuse to produce a result.
enum ErrorCode : string
{
    /// Operand shapes are incompatible (add, mul, solve, qr, lstsq).
    dimensionMismatch = "dimension_mismatch",
    /// A square matrix was required.
    notSquare = "not_square",
    /// A symmetric matrix was required.
    notSymmetric = "not_symmetric",
    /// Cholesky met a non-positive pivot.
    notPositiveDefinite = "not_positive_definite",
    /// A pivot, a diagonal entry or a singular value was exactly zero.
    singular = "singular",
}

/// Thrown by every operation that cannot be carried out.
class LinAlgException : Exception
{
    /// What went wrong.
    ErrorCode code;

    /// Builds an exception for `code`; the message is the code's text.
    this(ErrorCode code, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(cast(string) code, file, line);
        this.code = code;
    }
}

/// Throws `LinAlgException(code)` unless `condition` holds.
void enforceCode(bool condition, ErrorCode code,
        string file = __FILE__, size_t line = __LINE__) @safe pure
{
    if (!condition)
        throw new LinAlgException(code, file, line);
}
