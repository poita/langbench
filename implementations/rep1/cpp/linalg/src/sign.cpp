#include "linalg/sign.hpp"

#include <cmath>

namespace linalg {

bool normalize_sign(Matrix& a, std::size_t col) noexcept {
    std::size_t best = 0;
    double best_abs = -1.0;
    for (std::size_t i = 0; i < a.rows(); ++i) {
        const double v = std::fabs(a(i, col));
        if (v > best_abs) {  // strict: the smallest index attaining the maximum wins
            best_abs = v;
            best = i;
        }
    }
    if (a.rows() == 0 || !(a(best, col) < 0.0)) return false;
    for (std::size_t i = 0; i < a.rows(); ++i) a(i, col) = -a(i, col);
    return true;
}

}  // namespace linalg
