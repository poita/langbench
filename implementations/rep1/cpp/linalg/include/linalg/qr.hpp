#pragma once
/// \file qr.hpp
/// Householder QR and linear least squares.

#include "linalg/matrix.hpp"

namespace linalg {

/// Thin QR: `A = Q R`, `Q` is `m x n` with orthonormal columns, `R` is `n x n`
/// upper triangular with a non-negative diagonal.
struct QR {
    Matrix Q;
    Matrix R;
};

/// Householder QR of an `m x n` matrix, `m >= n`.
/// Throws Error(DimensionMismatch) if `m < n`. Rank-deficient input is accepted.
QR qr_factor(const Matrix& a);

/// Minimises `‖A X - B‖F` via QR and back substitution (`A` is `m x n`, `m >= n`).
/// Throws DimensionMismatch (m < n, or B's rows != m) or Singular (zero diagonal in R).
Matrix lstsq(const Matrix& a, const Matrix& b);

}  // namespace linalg
