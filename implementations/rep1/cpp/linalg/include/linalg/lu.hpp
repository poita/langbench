#pragma once
/// \file lu.hpp
/// LU factorisation with partial pivoting and its users: determinant, solve, inverse.

#include <cstddef>
#include <vector>

#include "linalg/matrix.hpp"

namespace linalg {

/// Result of `P A = L U`.
struct LU {
    Matrix P;                       ///< permutation matrix, `P[i][perm[i]] = 1`
    Matrix L;                       ///< unit lower triangular
    Matrix U;                       ///< upper triangular
    std::vector<std::size_t> perm;  ///< `perm[i]` = original row now in row i
    int swaps = 0;                  ///< number of row interchanges performed
};

/// Right-looking Gaussian elimination with partial pivoting (first maximal pivot wins).
/// Throws Error(NotSquare) or Error(Singular) (exactly zero pivot).
LU lu_factor(const Matrix& a);

/// Determinant via the same elimination; `0.0` when a pivot is exactly zero.
/// Throws Error(NotSquare).
double determinant(const Matrix& a);

/// Solves `A X = B`. Throws NotSquare, DimensionMismatch (checked in that
/// order) or Singular.
Matrix solve(const Matrix& a, const Matrix& b);

/// `A⁻¹`, computed as `solve(A, I)`. Throws NotSquare or Singular.
Matrix inverse(const Matrix& a);

}  // namespace linalg
