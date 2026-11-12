#pragma once
#include <gtest/gtest.h>

#include <cmath>
#include <functional>
#include <cstdint>

#include "linalg/linalg.hpp"

namespace testutil {

inline void expect_near(const linalg::Matrix& a, const linalg::Matrix& b, double tol) {
    ASSERT_EQ(a.rows(), b.rows());
    ASSERT_EQ(a.cols(), b.cols());
    for (std::size_t i = 0; i < a.rows(); ++i)
        for (std::size_t j = 0; j < a.cols(); ++j)
            EXPECT_NEAR(a(i, j), b(i, j), tol) << "at (" << i << "," << j << ")";
}

/// Deterministic pseudo-random matrix with entries in [-1, 1).
inline linalg::Matrix random_matrix(std::size_t m, std::size_t n, std::uint64_t seed) {
    linalg::Matrix a(m, n);
    std::uint64_t s = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    for (std::size_t i = 0; i < m; ++i)
        for (std::size_t j = 0; j < n; ++j) {
            s = s * 6364136223846793005ULL + 1442695040888963407ULL;
            a(i, j) = static_cast<double>(s >> 11) / 4503599627370496.0 - 1.0;
        }
    return a;
}


}  // namespace testutil
