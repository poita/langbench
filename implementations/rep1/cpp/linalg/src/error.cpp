#include "linalg/error.hpp"

namespace linalg {

const char* error_code_name(ErrorCode code) noexcept {
    switch (code) {
        case ErrorCode::DimensionMismatch: return "dimension_mismatch";
        case ErrorCode::NotSquare: return "not_square";
        case ErrorCode::NotSymmetric: return "not_symmetric";
        case ErrorCode::NotPositiveDefinite: return "not_positive_definite";
        case ErrorCode::Singular: return "singular";
    }
    return "unknown";
}

}  // namespace linalg
