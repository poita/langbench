#pragma once
/// \file sign.hpp
/// Sign convention for eigen/singular vectors.

#include "linalg/matrix.hpp"

namespace linalg {

/// Let i* be the smallest index attaining max |A[i][col]|. If that entry is
/// negative, negate the whole column. An all-zero column is left alone.
/// Returns true when the column was negated.
bool normalize_sign(Matrix& a, std::size_t col) noexcept;

}  // namespace linalg
