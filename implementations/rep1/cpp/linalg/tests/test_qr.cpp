#include "test_util.hpp"

using namespace linalg;
using testutil::expect_near;

TEST(QR, SignNormalisedColumn) {
    const QR f = qr_factor(Matrix::from_rows({{3}, {4}}));
    expect_near(f.Q, Matrix::from_rows({{0.6}, {0.8}}), 1e-15);
    expect_near(f.R, Matrix::from_rows({{5}}), 1e-15);
}

TEST(QR, TallRandom) {
    const Matrix a = testutil::random_matrix(40, 12, 4);
    const QR f = qr_factor(a);
    ASSERT_EQ(f.Q.rows(), 40u);
    ASSERT_EQ(f.Q.cols(), 12u);
    ASSERT_EQ(f.R.rows(), 12u);
    expect_near(multiply(f.Q, f.R), a, 1e-13);
    expect_near(multiply(transpose(f.Q), f.Q), Matrix::identity(12), 1e-13);
    for (std::size_t i = 0; i < 12; ++i) {
        EXPECT_GE(f.R(i, i), 0.0);
        for (std::size_t j = 0; j < i; ++j) EXPECT_EQ(f.R(i, j), 0.0);
    }
}

TEST(QR, RankDeficientStillSucceeds) {
    const Matrix a = Matrix::from_rows({{1, 0}, {2, 0}, {3, 0}});  // zero second column
    const QR f = qr_factor(a);
    expect_near(multiply(f.Q, f.R), a, 1e-14);
    EXPECT_THROW(lstsq(a, Matrix(3, 1)), Error);
}

TEST(QR, WideIsDimensionMismatch) {
    try {
        qr_factor(Matrix(2, 3));
        FAIL();
    } catch (const Error& e) {
        EXPECT_EQ(e.code(), ErrorCode::DimensionMismatch);
    }
}

TEST(Lstsq, FitsLine) {
    // y = 1 + 2x sampled with symmetric noise
    const Matrix a = Matrix::from_rows({{1, 0}, {1, 1}, {1, 2}, {1, 3}});
    const Matrix b = Matrix::from_rows({{1.1}, {2.9}, {5.1}, {6.9}});
    const Matrix x = lstsq(a, b);
    EXPECT_NEAR(x(0, 0), 1.06, 1e-12);
    EXPECT_NEAR(x(1, 0), 1.96, 1e-12);
}

TEST(Lstsq, NormalEquationsHold) {
    const Matrix a = testutil::random_matrix(25, 6, 5), b = testutil::random_matrix(25, 2, 6);
    const Matrix x = lstsq(a, b);
    const Matrix at = transpose(a);
    expect_near(multiply(at, multiply(a, x)), multiply(at, b), 1e-12);
}

TEST(Lstsq, RowMismatch) {
    EXPECT_THROW(lstsq(Matrix::identity(3), Matrix(2, 1)), Error);
}
