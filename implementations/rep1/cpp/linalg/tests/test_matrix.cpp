#include "test_util.hpp"

using namespace linalg;

TEST(Matrix, AddMulTranspose) {
    const Matrix a = Matrix::from_rows({{1, 2}, {3, 4}});
    const Matrix b = Matrix::from_rows({{0.5, 0}, {0, -1.5}});
    EXPECT_EQ(add(a, b), Matrix::from_rows({{1.5, 2}, {3, 2.5}}));
    EXPECT_EQ(multiply(a, b), Matrix::from_rows({{0.5, -3}, {1.5, -6}}));
    EXPECT_EQ(transpose(Matrix::from_rows({{1, 2, 3}})), Matrix::from_rows({{1}, {2}, {3}}));
}

TEST(Matrix, ShapeErrors) {
    const Matrix a(2, 3), b(3, 2);
    try {
        add(a, b);
        FAIL();
    } catch (const Error& e) {
        EXPECT_EQ(e.code(), ErrorCode::DimensionMismatch);
    }
    EXPECT_THROW(multiply(a, a), Error);
    EXPECT_NO_THROW(multiply(a, b));
}

TEST(Matrix, Norms) {
    const Matrix a = Matrix::from_rows({{1, -2}, {-3, 4}});
    EXPECT_DOUBLE_EQ(norm1(a), 6.0);
    EXPECT_DOUBLE_EQ(norm_inf(a), 7.0);
    EXPECT_DOUBLE_EQ(norm_fro(a), std::sqrt(30.0));
}

TEST(Matrix, Symmetry) {
    EXPECT_TRUE(Matrix::from_rows({{1, 2}, {2, 3}}).is_symmetric());
    EXPECT_FALSE(Matrix::from_rows({{1, 2}, {2.0000001, 3}}).is_symmetric());
    EXPECT_FALSE(Matrix(2, 3).is_symmetric());
}

TEST(Sign, SmallestIndexOfMaximumDecides) {
    Matrix a = Matrix::from_rows({{-2, 1}, {1, -3}, {2, 0}});
    EXPECT_TRUE(normalize_sign(a, 0));  // |-2| ties |2|; index 0 is negative
    EXPECT_EQ(a(0, 0), 2.0);
    EXPECT_TRUE(normalize_sign(a, 1));
    EXPECT_EQ(a(1, 1), 3.0);
    Matrix z(2, 1);
    EXPECT_FALSE(normalize_sign(z, 0));
}
