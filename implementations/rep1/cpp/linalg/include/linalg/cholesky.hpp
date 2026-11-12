#pragma once
/// \file cholesky.hpp
/// Cholesky factorisation.

#include "linalg/matrix.hpp"

namespace linalg {

/// Lower triangular `L` with `A = L Lᵀ` and positive diagonal.
/// Throws NotSquare, NotSymmetric (exact comparison) or NotPositiveDefinite.
Matrix cholesky(const Matrix& a);

}  // namespace linalg
