#include "linalg/cholesky.hpp"

#include <cmath>

#include "linalg/error.hpp"

namespace linalg {

Matrix cholesky(const Matrix& a) {
    if (!a.is_square()) throw Error(ErrorCode::NotSquare);
    if (!a.is_symmetric()) throw Error(ErrorCode::NotSymmetric);
    const std::size_t n = a.rows();
    Matrix L(n, n);
    for (std::size_t j = 0; j < n; ++j) {
        double sum = 0.0;
        for (std::size_t k = 0; k < j; ++k) sum += L(j, k) * L(j, k);
        const double s = a(j, j) - sum;
        if (s <= 0.0) throw Error(ErrorCode::NotPositiveDefinite);
        L(j, j) = std::sqrt(s);
        for (std::size_t i = j + 1; i < n; ++i) {
            double dot = 0.0;
            for (std::size_t k = 0; k < j; ++k) dot += L(i, k) * L(j, k);
            L(i, j) = (a(i, j) - dot) / L(j, j);
        }
    }
    return L;
}

}  // namespace linalg
