#include "linalg/eigen.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>

#include "linalg/error.hpp"
#include "linalg/sign.hpp"

namespace linalg {
namespace {

constexpr int kMaxSweeps = 60;
constexpr double kTolerance = 1e-14;

double off_norm(const Matrix& M) {
    double s = 0.0;
    for (std::size_t i = 0; i < M.rows(); ++i)
        for (std::size_t j = i + 1; j < M.cols(); ++j) s += M(i, j) * M(i, j);
    return std::sqrt(2.0 * s);
}

}  // namespace

SymmetricEigen eig_symmetric(const Matrix& a) {
    if (!a.is_square()) throw Error(ErrorCode::NotSquare);
    if (!a.is_symmetric()) throw Error(ErrorCode::NotSymmetric);
    const std::size_t n = a.rows();

    Matrix M = a;
    Matrix Vt = Matrix::identity(n);  // row j holds column j of V (contiguous updates)
    const double phi = norm_fro(a);
    double prev = std::numeric_limits<double>::infinity();

    for (int sweep = 0; sweep < kMaxSweeps; ++sweep) {
        const double off = off_norm(M);
        if (off <= kTolerance * phi || off >= prev) break;
        prev = off;
        for (std::size_t p = 0; p + 1 < n; ++p) {
            for (std::size_t q = p + 1; q < n; ++q) {
                const double apq = M(p, q);
                if (apq == 0.0) continue;
                const double theta = (M(q, q) - M(p, p)) / (2.0 * apq);
                const double t = theta >= 0.0 ? 1.0 / (theta + std::sqrt(theta * theta + 1.0))
                                              : -1.0 / (-theta + std::sqrt(theta * theta + 1.0));
                const double c = 1.0 / std::sqrt(t * t + 1.0);
                const double s = t * c;
                for (std::size_t i = 0; i < n; ++i) {  // columns
                    double* r = M.row(i);
                    const double x = r[p], y = r[q];
                    r[p] = c * x - s * y;
                    r[q] = s * x + c * y;
                }
                double* rp = M.row(p);
                double* rq = M.row(q);
                for (std::size_t j = 0; j < n; ++j) {  // rows
                    const double x = rp[j], y = rq[j];
                    rp[j] = c * x - s * y;
                    rq[j] = s * x + c * y;
                }
                M(p, q) = 0.0;
                M(q, p) = 0.0;
                double* vp = Vt.row(p);
                double* vq = Vt.row(q);
                for (std::size_t i = 0; i < n; ++i) {
                    const double x = vp[i], y = vq[i];
                    vp[i] = c * x - s * y;
                    vq[i] = s * x + c * y;
                }
            }
        }
    }

    std::vector<std::size_t> order(n);
    std::iota(order.begin(), order.end(), std::size_t{0});
    std::stable_sort(order.begin(), order.end(),
                     [&](std::size_t x, std::size_t y) { return M(x, x) < M(y, y); });

    SymmetricEigen out;
    out.w.resize(n);
    out.V = Matrix(n, n);
    for (std::size_t j = 0; j < n; ++j) {
        out.w[j] = M(order[j], order[j]);
        for (std::size_t i = 0; i < n; ++i) out.V(i, j) = Vt(order[j], i);
        normalize_sign(out.V, j);
    }
    return out;
}

}  // namespace linalg
