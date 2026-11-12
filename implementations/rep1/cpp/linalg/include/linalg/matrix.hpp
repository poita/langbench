#pragma once
/// \file matrix.hpp
/// Dense, row-major matrix of doubles plus the elementwise operations,
/// product, transpose and norms.

#include <cstddef>
#include <initializer_list>
#include <vector>

namespace linalg {

/// A dense `rows x cols` matrix of `double`, stored row-major.
class Matrix {
public:
    Matrix() = default;
    /// Creates a `rows x cols` matrix with every entry equal to `fill`.
    Matrix(std::size_t rows, std::size_t cols, double fill = 0.0);

    /// The `n x n` identity.
    static Matrix identity(std::size_t n);
    /// Builds a matrix from nested initializer lists (all rows must have equal length).
    static Matrix from_rows(std::initializer_list<std::initializer_list<double>> rows);

    std::size_t rows() const noexcept { return rows_; }
    std::size_t cols() const noexcept { return cols_; }
    bool is_square() const noexcept { return rows_ == cols_; }
    /// True when square and `A[i][j] == A[j][i]` exactly for all i, j.
    bool is_symmetric() const noexcept;

    double& operator()(std::size_t i, std::size_t j) noexcept { return data_[i * cols_ + j]; }
    double operator()(std::size_t i, std::size_t j) const noexcept { return data_[i * cols_ + j]; }

    /// Pointer to the first entry of row `i` (entries of a row are contiguous).
    double* row(std::size_t i) noexcept { return data_.data() + i * cols_; }
    const double* row(std::size_t i) const noexcept { return data_.data() + i * cols_; }

    const std::vector<double>& data() const noexcept { return data_; }

    friend bool operator==(const Matrix& a, const Matrix& b) noexcept {
        return a.rows_ == b.rows_ && a.cols_ == b.cols_ && a.data_ == b.data_;
    }

private:
    std::size_t rows_ = 0, cols_ = 0;
    std::vector<double> data_;
};

/// `A + B`. Throws Error(DimensionMismatch) if the shapes differ.
Matrix add(const Matrix& a, const Matrix& b);

/// `A B`, each entry one running sum over increasing k.
/// Throws Error(DimensionMismatch) unless `a.cols() == b.rows()`.
Matrix multiply(const Matrix& a, const Matrix& b);

/// `Aᵀ`.
Matrix transpose(const Matrix& a);

/// Maximum absolute column sum (columns summed over increasing row index).
double norm1(const Matrix& a);
/// Maximum absolute row sum (rows summed over increasing column index).
double norm_inf(const Matrix& a);
/// Frobenius norm; squares summed row by row.
double norm_fro(const Matrix& a);

}  // namespace linalg
