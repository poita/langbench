#include "linalg/matrix.hpp"

#include <algorithm>
#include <cmath>

#include "linalg/error.hpp"

namespace linalg {

Matrix::Matrix(std::size_t rows, std::size_t cols, double fill)
    : rows_(rows), cols_(cols), data_(rows * cols, fill) {}

Matrix Matrix::identity(std::size_t n) {
    Matrix m(n, n);
    for (std::size_t i = 0; i < n; ++i) m(i, i) = 1.0;
    return m;
}

Matrix Matrix::from_rows(std::initializer_list<std::initializer_list<double>> rows) {
    const std::size_t r = rows.size();
    const std::size_t c = r == 0 ? 0 : rows.begin()->size();
    Matrix m(r, c);
    std::size_t i = 0;
    for (const auto& row : rows) {
        if (row.size() != c) throw std::invalid_argument("Matrix::from_rows: ragged rows");
        std::copy(row.begin(), row.end(), m.row(i++));
    }
    return m;
}

bool Matrix::is_symmetric() const noexcept {
    if (rows_ != cols_) return false;
    for (std::size_t i = 0; i < rows_; ++i)
        for (std::size_t j = 0; j < i; ++j)
            if ((*this)(i, j) != (*this)(j, i)) return false;
    return true;
}

Matrix add(const Matrix& a, const Matrix& b) {
    if (a.rows() != b.rows() || a.cols() != b.cols()) throw Error(ErrorCode::DimensionMismatch);
    Matrix c(a.rows(), a.cols());
    const auto& x = a.data();
    const auto& y = b.data();
    double* out = c.row(0);
    for (std::size_t i = 0; i < x.size(); ++i) out[i] = x[i] + y[i];
    return c;
}

Matrix multiply(const Matrix& a, const Matrix& b) {
    if (a.cols() != b.rows()) throw Error(ErrorCode::DimensionMismatch);
    const std::size_t m = a.rows(), k = a.cols(), n = b.cols();
    Matrix c(m, n);
    // i-k-j loop order: each c(i,j) is still one running sum over increasing k,
    // but the inner loop walks rows of B and C contiguously.
    for (std::size_t i = 0; i < m; ++i) {
        double* ci = c.row(i);
        for (std::size_t p = 0; p < k; ++p) {
            const double aip = a(i, p);
            const double* bp = b.row(p);
            for (std::size_t j = 0; j < n; ++j) ci[j] += aip * bp[j];
        }
    }
    return c;
}

Matrix transpose(const Matrix& a) {
    Matrix t(a.cols(), a.rows());
    for (std::size_t i = 0; i < a.rows(); ++i)
        for (std::size_t j = 0; j < a.cols(); ++j) t(j, i) = a(i, j);
    return t;
}

double norm1(const Matrix& a) {
    double best = 0.0;
    for (std::size_t j = 0; j < a.cols(); ++j) {
        double s = 0.0;
        for (std::size_t i = 0; i < a.rows(); ++i) s += std::fabs(a(i, j));
        best = std::max(best, s);
    }
    return best;
}

double norm_inf(const Matrix& a) {
    double best = 0.0;
    for (std::size_t i = 0; i < a.rows(); ++i) {
        double s = 0.0;
        for (std::size_t j = 0; j < a.cols(); ++j) s += std::fabs(a(i, j));
        best = std::max(best, s);
    }
    return best;
}

double norm_fro(const Matrix& a) {
    double s = 0.0;
    for (std::size_t i = 0; i < a.rows(); ++i)
        for (std::size_t j = 0; j < a.cols(); ++j) s += a(i, j) * a(i, j);
    return std::sqrt(s);
}

}  // namespace linalg
