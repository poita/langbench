#pragma once
/// \file penalty.hpp
/// Mask penalty score (rules N1-N4 of SPEC section 12).

#include "qrcode/matrix.hpp"

namespace qrcode {

/// Penalty of a complete symbol (all modules, including function patterns).
int penaltyScore(const Matrix& m);

}  // namespace qrcode
