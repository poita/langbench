#include "linalg/svd.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

#include "linalg/error.hpp"
#include "linalg/sign.hpp"

namespace linalg {
namespace {

constexpr int kMaxSweeps = 60;
constexpr double kSkipTolerance = 1e-14;

/// One-sided Jacobi on a working matrix given by its columns (`Wt` is n' x m',
/// row j = column j of W, so m' >= n'). Returns the sorted factors of W:
/// U' (m' x n'), s, V' (n' x n').
SVD jacobi_columns(Matrix Wt) {
    const std::size_t n = Wt.rows(), m = Wt.cols();
    Matrix Vt = Matrix::identity(n);  // row j = column j of V

    for (int sweep = 0; sweep < kMaxSweeps; ++sweep) {
        bool rotated = false;
        for (std::size_t p = 0; p + 1 < n; ++p) {
            for (std::size_t q = p + 1; q < n; ++q) {
                double* wp = Wt.row(p);
                double* wq = Wt.row(q);
                double alpha = 0.0, beta = 0.0, gamma = 0.0;
                for (std::size_t i = 0; i < m; ++i) {
                    alpha += wp[i] * wp[i];
                    beta += wq[i] * wq[i];
                    gamma += wp[i] * wq[i];
                }
                if (gamma == 0.0 || alpha == 0.0 || beta == 0.0) continue;
                if (std::fabs(gamma) <= kSkipTolerance * std::sqrt(alpha * beta)) continue;
                const double zeta = (beta - alpha) / (2.0 * gamma);
                const double t = zeta >= 0.0 ? 1.0 / (zeta + std::sqrt(zeta * zeta + 1.0))
                                             : -1.0 / (-zeta + std::sqrt(zeta * zeta + 1.0));
                const double c = 1.0 / std::sqrt(t * t + 1.0);
                const double s = t * c;
                for (std::size_t i = 0; i < m; ++i) {
                    const double x = wp[i], y = wq[i];
                    wp[i] = c * x - s * y;
                    wq[i] = s * x + c * y;
                }
                double* vp = Vt.row(p);
                double* vq = Vt.row(q);
                for (std::size_t i = 0; i < n; ++i) {
                    const double x = vp[i], y = vq[i];
                    vp[i] = c * x - s * y;
                    vq[i] = s * x + c * y;
                }
                rotated = true;
            }
        }
        if (!rotated) break;
    }

    std::vector<double> sigma(n);
    for (std::size_t j = 0; j < n; ++j) {
        double ss = 0.0;
        const double* wj = Wt.row(j);
        for (std::size_t i = 0; i < m; ++i) ss += wj[i] * wj[i];
        sigma[j] = std::sqrt(ss);
    }
    std::vector<std::size_t> order(n);
    std::iota(order.begin(), order.end(), std::size_t{0});
    std::stable_sort(order.begin(), order.end(),
                     [&](std::size_t x, std::size_t y) { return sigma[x] > sigma[y]; });

    SVD out;
    out.U = Matrix(m, n);
    out.V = Matrix(n, n);
    out.s.resize(n);
    for (std::size_t j = 0; j < n; ++j) {
        const std::size_t src = order[j];
        out.s[j] = sigma[src];
        for (std::size_t i = 0; i < m; ++i)
            out.U(i, j) = sigma[src] == 0.0 ? 0.0 : Wt(src, i) / sigma[src];
        for (std::size_t i = 0; i < n; ++i) out.V(i, j) = Vt(src, i);
    }
    return out;
}

}  // namespace

SVD svd(const Matrix& a) {
    // Columns of the working matrix are rows of A when m < n (working on Aᵀ),
    // and columns of A otherwise.
    SVD r;
    if (a.rows() >= a.cols()) {
        r = jacobi_columns(transpose(a));
    } else {
        SVD t = jacobi_columns(a);  // factors of Aᵀ: left = right vectors of A
        r.U = std::move(t.V);
        r.s = std::move(t.s);
        r.V = std::move(t.U);
    }
    for (std::size_t j = 0; j < r.s.size(); ++j)
        if (normalize_sign(r.U, j))
            for (std::size_t i = 0; i < r.V.rows(); ++i) r.V(i, j) = -r.V(i, j);
    return r;
}

double cond(const Matrix& a) {
    const SVD r = svd(a);
    const double smax = r.s.front(), smin = r.s.back();
    if (smin == 0.0) throw Error(ErrorCode::Singular);
    return smax / smin;
}

}  // namespace linalg
