#include "test_util.hpp"

using namespace linalg;
using testutil::expect_near;

TEST(Eigen, TwoByTwoExample) {
    const SymmetricEigen e = eig_symmetric(Matrix::from_rows({{2, 1}, {1, 3}}));
    EXPECT_NEAR(e.w[0], (5 - std::sqrt(5.0)) / 2, 1e-14);
    EXPECT_NEAR(e.w[1], (5 + std::sqrt(5.0)) / 2, 1e-14);
    EXPECT_NEAR(e.V(0, 0), 0.8506508083520399, 1e-14);
    EXPECT_NEAR(e.V(1, 0), -0.5257311121191336, 1e-14);
    EXPECT_NEAR(e.V(0, 1), 0.5257311121191336, 1e-14);
    EXPECT_NEAR(e.V(1, 1), 0.8506508083520399, 1e-14);
}

TEST(Eigen, RandomSymmetric) {
    Matrix a = testutil::random_matrix(25, 25, 8);
    for (std::size_t i = 0; i < 25; ++i)
        for (std::size_t j = 0; j < i; ++j) a(i, j) = a(j, i);
    const SymmetricEigen e = eig_symmetric(a);
    expect_near(multiply(transpose(e.V), e.V), Matrix::identity(25), 1e-12);
    Matrix vd = e.V;
    for (std::size_t j = 0; j < 25; ++j)
        for (std::size_t i = 0; i < 25; ++i) vd(i, j) *= e.w[j];
    expect_near(multiply(a, e.V), vd, 1e-12);
    for (std::size_t j = 1; j < 25; ++j) EXPECT_LE(e.w[j - 1], e.w[j]);
}

TEST(Eigen, DiagonalInputSortsAndKeepsIdentityColumns) {
    const SymmetricEigen e = eig_symmetric(Matrix::from_rows({{3, 0}, {0, 1}}));
    EXPECT_EQ(e.w[0], 1.0);
    EXPECT_EQ(e.w[1], 3.0);
    EXPECT_EQ(e.V, Matrix::from_rows({{0, 1}, {1, 0}}));
}

TEST(Eigen, Errors) {
    EXPECT_THROW(eig_symmetric(Matrix(2, 3)), Error);
    EXPECT_THROW(eig_symmetric(Matrix::from_rows({{1, 2}, {3, 1}})), Error);
}
