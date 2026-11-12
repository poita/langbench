#pragma once
/// \file eigen.hpp
/// Symmetric eigendecomposition by cyclic Jacobi.

#include <vector>

#include "linalg/matrix.hpp"

namespace linalg {

/// `A = V diag(w) Vᵀ`.
struct SymmetricEigen {
    std::vector<double> w;  ///< eigenvalues, ascending
    Matrix V;               ///< orthogonal; column j is the unit eigenvector of w[j],
                            ///< sign-normalised (see normalize_sign)
};

/// Cyclic Jacobi eigensolver (at most 60 sweeps). Throws NotSquare or NotSymmetric.
SymmetricEigen eig_symmetric(const Matrix& a);

}  // namespace linalg
