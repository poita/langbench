#include "test_util.hpp"

using namespace linalg;
using testutil::expect_near;

namespace {
void check_svd(const Matrix& a) {
    const SVD f = svd(a);
    const std::size_t k = std::min(a.rows(), a.cols());
    ASSERT_EQ(f.U.rows(), a.rows());
    ASSERT_EQ(f.U.cols(), k);
    ASSERT_EQ(f.V.rows(), a.cols());
    ASSERT_EQ(f.V.cols(), k);
    ASSERT_EQ(f.s.size(), k);
    Matrix us = f.U;
    for (std::size_t j = 0; j < k; ++j)
        for (std::size_t i = 0; i < us.rows(); ++i) us(i, j) *= f.s[j];
    expect_near(multiply(us, transpose(f.V)), a, 1e-12);
    expect_near(multiply(transpose(f.U), f.U), Matrix::identity(k), 1e-12);
    expect_near(multiply(transpose(f.V), f.V), Matrix::identity(k), 1e-12);
    for (std::size_t j = 1; j < k; ++j) EXPECT_GE(f.s[j - 1], f.s[j]);
}
}  // namespace

TEST(SVD, Tall) { check_svd(testutil::random_matrix(30, 8, 9)); }
TEST(SVD, Wide) { check_svd(testutil::random_matrix(7, 20, 10)); }
TEST(SVD, Square) { check_svd(testutil::random_matrix(12, 12, 11)); }
TEST(SVD, SingleRowAndColumn) {
    check_svd(Matrix::from_rows({{3, 4}}));
    check_svd(Matrix::from_rows({{3}, {-4}}));
}

TEST(SVD, KnownValuesAndSigns) {
    const SVD f = svd(Matrix::from_rows({{3, 0}, {0, -2}}));
    EXPECT_NEAR(f.s[0], 3.0, 1e-15);
    EXPECT_NEAR(f.s[1], 2.0, 1e-15);
    // U columns are sign-normalised: largest entry positive; V absorbs the sign.
    EXPECT_NEAR(f.U(0, 0), 1.0, 1e-15);
    EXPECT_NEAR(f.U(1, 1), 1.0, 1e-15);
    EXPECT_NEAR(f.V(1, 1), -1.0, 1e-15);
}

TEST(Cond, Value) {
    EXPECT_NEAR(cond(Matrix::from_rows({{3, 0}, {0, -2}})), 1.5, 1e-14);
    EXPECT_NEAR(cond(Matrix::from_rows({{1, 2, 3}})), 1.0, 1e-14);
}

TEST(Cond, SingularThrows) {
    try {
        cond(Matrix::from_rows({{1, 1}, {0, 0}}));
        FAIL();
    } catch (const Error& e) {
        EXPECT_EQ(e.code(), ErrorCode::Singular);
    }
}
