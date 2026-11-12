#include "linalg/qr.hpp"

#include <cmath>
#include <vector>

#include "linalg/error.hpp"

namespace linalg {

QR qr_factor(const Matrix& a) {
    const std::size_t m = a.rows(), n = a.cols();
    if (m < n) throw Error(ErrorCode::DimensionMismatch);

    Matrix R = a;
    std::vector<std::vector<double>> vs(n);  // reflector k acts on rows k..m-1; empty = identity
    std::vector<double> w(n);
    for (std::size_t k = 0; k < n; ++k) {
        double ss = 0.0;
        for (std::size_t i = k; i < m; ++i) ss += R(i, k) * R(i, k);
        const double nu = std::sqrt(ss);
        if (nu == 0.0) {
            for (std::size_t i = k + 1; i < m; ++i) R(i, k) = 0.0;
            continue;
        }
        const double alpha = R(k, k) >= 0.0 ? -nu : nu;
        std::vector<double> v(m - k);
        for (std::size_t i = k; i < m; ++i) v[i - k] = R(i, k);
        v[0] -= alpha;
        double vs2 = 0.0;
        for (double x : v) vs2 += x * x;
        const double vn = std::sqrt(vs2);
        for (double& x : v) x /= vn;

        // R[k.., j] -= 2 (vᵀ R[k.., j]) v for j > k; dots accumulate over increasing i.
        for (std::size_t j = k + 1; j < n; ++j) w[j] = 0.0;
        for (std::size_t i = k; i < m; ++i) {
            const double vi = v[i - k];
            const double* ri = R.row(i);
            for (std::size_t j = k + 1; j < n; ++j) w[j] += vi * ri[j];
        }
        for (std::size_t i = k; i < m; ++i) {
            const double vi = v[i - k];
            double* ri = R.row(i);
            for (std::size_t j = k + 1; j < n; ++j) ri[j] -= 2.0 * w[j] * vi;
        }
        R(k, k) = alpha;
        for (std::size_t i = k + 1; i < m; ++i) R(i, k) = 0.0;
        vs[k] = std::move(v);
    }

    // Q = first n columns of I, with reflectors applied in reverse order.
    Matrix Q(m, n);
    for (std::size_t j = 0; j < n; ++j) Q(j, j) = 1.0;
    std::vector<double> d(n);
    for (std::size_t kk = n; kk-- > 0;) {
        const std::vector<double>& v = vs[kk];
        if (v.empty()) continue;
        for (std::size_t j = 0; j < n; ++j) d[j] = 0.0;
        for (std::size_t i = kk; i < m; ++i) {
            const double vi = v[i - kk];
            const double* qi = Q.row(i);
            for (std::size_t j = 0; j < n; ++j) d[j] += vi * qi[j];
        }
        for (std::size_t i = kk; i < m; ++i) {
            const double vi = v[i - kk];
            double* qi = Q.row(i);
            for (std::size_t j = 0; j < n; ++j) qi[j] -= 2.0 * d[j] * vi;
        }
    }

    // Thin R (n x n) with a non-negative diagonal.
    QR out{std::move(Q), Matrix(n, n)};
    for (std::size_t i = 0; i < n; ++i)
        for (std::size_t j = i; j < n; ++j) out.R(i, j) = R(i, j);
    for (std::size_t j = 0; j < n; ++j) {
        if (out.R(j, j) < 0.0) {
            for (std::size_t c = j; c < n; ++c) out.R(j, c) = -out.R(j, c);
            for (std::size_t i = 0; i < m; ++i) out.Q(i, j) = -out.Q(i, j);
        }
    }
    return out;
}

Matrix lstsq(const Matrix& a, const Matrix& b) {
    const std::size_t m = a.rows(), n = a.cols(), k = b.cols();
    if (m < n) throw Error(ErrorCode::DimensionMismatch);
    if (b.rows() != m) throw Error(ErrorCode::DimensionMismatch);
    const QR f = qr_factor(a);
    for (std::size_t i = 0; i < n; ++i)
        if (f.R(i, i) == 0.0) throw Error(ErrorCode::Singular);

    Matrix x(n, k);
    std::vector<double> y(n);
    for (std::size_t c = 0; c < k; ++c) {
        for (std::size_t j = 0; j < n; ++j) {  // y = Qᵀ b[:, c]
            double s = 0.0;
            for (std::size_t i = 0; i < m; ++i) s += f.Q(i, j) * b(i, c);
            y[j] = s;
        }
        for (std::size_t ii = n; ii-- > 0;) {  // back substitution R x = y
            double v = y[ii];
            for (std::size_t j = ii + 1; j < n; ++j) v -= f.R(ii, j) * x(j, c);
            x(ii, c) = v / f.R(ii, ii);
        }
    }
    return x;
}

}  // namespace linalg
