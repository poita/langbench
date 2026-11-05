/**
 * Error types shared by the whole library.
 *
 * Every numerical routine that can legitimately fail on valid-looking input
 * (wrong shapes, singular matrix, ...) reports it by throwing a
 * $(LREF LinalgException) carrying one of the $(LREF ErrorCode) values.
 */
module linalg.errors;

import std.conv : to;

/// The reasons a linear-algebra operation can be refused.
enum ErrorCode
{
    /// Operand shapes are incompatible (e.g. `mul` of 2x3 with 2x3).
    dimension_mismatch,
    /// A square matrix was required.
    not_square,
    /// A symmetric matrix was required (exact comparison of entries).
    not_symmetric,
    /// Cholesky met a non-positive pivot.
    not_positive_definite,
    /// A pivot, diagonal entry or singular value was exactly zero.
    singular,
}

/// Exception thrown by the library; `code` says which failure occurred.
class LinalgException : Exception
{
    /// The machine-readable reason.
    ErrorCode code;

    ///
    this(ErrorCode code, string file = __FILE__, size_t line = __LINE__) pure
    {
        this.code = code;
        super(code.to!string, file, line);
    }
}

/// Throw `LinalgException(code)` unless `cond` holds.
void enforceCode(bool cond, ErrorCode code, string file = __FILE__, size_t line = __LINE__) pure
{
    if (!cond)
        throw new LinalgException(code, file, line);
}
