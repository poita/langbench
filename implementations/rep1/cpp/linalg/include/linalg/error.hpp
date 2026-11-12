#pragma once
/// \file error.hpp
/// Error taxonomy shared by every linalg operation.

#include <stdexcept>
#include <string>

namespace linalg {

/// Reasons an operation can be refused or can fail numerically.
enum class ErrorCode {
    DimensionMismatch,   ///< operand shapes are incompatible
    NotSquare,           ///< a square matrix was required
    NotSymmetric,        ///< exact symmetry (A[i][j] == A[j][i]) was required
    NotPositiveDefinite, ///< Cholesky met a non-positive pivot
    Singular,            ///< a pivot / diagonal entry / singular value was exactly zero
};

/// Stable textual name of a code (`"dimension_mismatch"`, `"not_square"`, ...).
const char* error_code_name(ErrorCode code) noexcept;

/// Exception thrown by the library for every ErrorCode condition.
class Error : public std::runtime_error {
public:
    explicit Error(ErrorCode code) : std::runtime_error(error_code_name(code)), code_(code) {}
    ErrorCode code() const noexcept { return code_; }

private:
    ErrorCode code_;
};

}  // namespace linalg
