#include "linalg/lu.hpp"

#include <cmath>
#include <utility>

#include "linalg/error.hpp"

namespace linalg {
namespace {

/// In-place elimination of `M` (spec 3.3). On success `M` holds the multipliers
/// below and U on/above the diagonal. Returns false at an exactly-zero pivot.
bool eliminate(Matrix& M, std::vector<std::size_t>& perm, int& swaps) {
    const std::size_t n = M.rows();
    perm.resize(n);
    for (std::size_t i = 0; i < n; ++i) perm[i] = i;
    swaps = 0;
    for (std::size_t k = 0; k < n; ++k) {
        std::size_t p = k;
        double best = std::fabs(M(k, k));
        for (std::size_t i = k + 1; i < n; ++i) {
            const double v = std::fabs(M(i, k));
            if (v > best) {
                best = v;
                p = i;
            }
        }
        if (best == 0.0) return false;
        if (p != k) {
            for (std::size_t j = 0; j < n; ++j) std::swap(M(k, j), M(p, j));
            std::swap(perm[k], perm[p]);
            ++swaps;
        }
        const double* rk = M.row(k);
        for (std::size_t i = k + 1; i < n; ++i) {
            double* ri = M.row(i);
            const double f = ri[k] / rk[k];
            ri[k] = f;
            for (std::size_t j = k + 1; j < n; ++j) ri[j] = ri[j] - f * rk[j];
        }
    }
    return true;
}

void require_square(const Matrix& a) {
    if (!a.is_square()) throw Error(ErrorCode::NotSquare);
}

/// Solves with an already-computed packed factorisation (`M` from eliminate()).
Matrix solve_packed(const Matrix& M, const std::vector<std::size_t>& perm, const Matrix& b) {
    const std::size_t n = M.rows(), k = b.cols();
    Matrix x(n, k);
    std::vector<double> col(n);
    for (std::size_t c = 0; c < k; ++c) {
        for (std::size_t i = 0; i < n; ++i) col[i] = b(perm[i], c);
        for (std::size_t i = 0; i < n; ++i) {  // forward: unit diagonal
            const double* li = M.row(i);
            double v = col[i];
            for (std::size_t j = 0; j < i; ++j) v -= li[j] * col[j];
            col[i] = v;
        }
        for (std::size_t ii = n; ii-- > 0;) {  // backward
            const double* ui = M.row(ii);
            double v = col[ii];
            for (std::size_t j = ii + 1; j < n; ++j) v -= ui[j] * col[j];
            col[ii] = v / ui[ii];
        }
        for (std::size_t i = 0; i < n; ++i) x(i, c) = col[i];
    }
    return x;
}

}  // namespace

LU lu_factor(const Matrix& a) {
    require_square(a);
    const std::size_t n = a.rows();
    Matrix M = a;
    LU r;
    if (!eliminate(M, r.perm, r.swaps)) throw Error(ErrorCode::Singular);
    r.P = Matrix(n, n);
    r.L = Matrix(n, n);
    r.U = Matrix(n, n);
    for (std::size_t i = 0; i < n; ++i) {
        r.P(i, r.perm[i]) = 1.0;
        for (std::size_t j = 0; j < i; ++j) r.L(i, j) = M(i, j);
        r.L(i, i) = 1.0;
        for (std::size_t j = i; j < n; ++j) r.U(i, j) = M(i, j);
    }
    return r;
}

double determinant(const Matrix& a) {
    require_square(a);
    Matrix M = a;
    std::vector<std::size_t> perm;
    int swaps = 0;
    if (!eliminate(M, perm, swaps)) return 0.0;
    double d = 1.0;
    for (std::size_t i = 0; i < M.rows(); ++i) d *= M(i, i);
    return swaps % 2 == 0 ? d : -d;
}

Matrix solve(const Matrix& a, const Matrix& b) {
    require_square(a);
    if (b.rows() != a.rows()) throw Error(ErrorCode::DimensionMismatch);
    Matrix M = a;
    std::vector<std::size_t> perm;
    int swaps = 0;
    if (!eliminate(M, perm, swaps)) throw Error(ErrorCode::Singular);
    return solve_packed(M, perm, b);
}

Matrix inverse(const Matrix& a) {
    require_square(a);
    return solve(a, Matrix::identity(a.rows()));
}

}  // namespace linalg
