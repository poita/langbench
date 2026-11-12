#pragma once
/// \file svd.hpp
/// Thin SVD by one-sided Jacobi and the 2-norm condition number.

#include <vector>

#include "linalg/matrix.hpp"

namespace linalg {

/// `A = U diag(s) Vᵀ` with `k = min(m, n)`.
struct SVD {
    Matrix U;               ///< m x k, orthonormal columns (zero column for a zero singular value)
    std::vector<double> s;  ///< k singular values, descending, non-negative
    Matrix V;               ///< n x k, orthonormal columns
};

/// One-sided Jacobi SVD (at most 60 sweeps). Columns of U are sign-normalised
/// and the matching columns of V negated.
SVD svd(const Matrix& a);

/// `σ_max / σ_min`. Throws Error(Singular) when σ_min is exactly zero.
double cond(const Matrix& a);

}  // namespace linalg
