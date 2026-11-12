#include "test_util.hpp"

using namespace linalg;

TEST(Cholesky, TwoByTwo) {
    EXPECT_EQ(cholesky(Matrix::from_rows({{4, 2}, {2, 5}})), Matrix::from_rows({{2, 0}, {1, 2}}));
}

TEST(Cholesky, RandomSpd) {
    const Matrix b = testutil::random_matrix(15, 15, 7);
    Matrix a = multiply(transpose(b), b);
    for (std::size_t i = 0; i < 15; ++i) a(i, i) += 1.0;
    const Matrix l = cholesky(a);
    testutil::expect_near(multiply(l, transpose(l)), a, 1e-13);
    for (std::size_t i = 0; i < 15; ++i)
        for (std::size_t j = i + 1; j < 15; ++j) EXPECT_EQ(l(i, j), 0.0);
}

TEST(Cholesky, Errors) {
    auto code = [](const Matrix& m) {
        try {
            cholesky(m);
        } catch (const Error& e) {
            return e.code();
        }
        return ErrorCode::Singular;
    };
    EXPECT_EQ(code(Matrix(2, 3)), ErrorCode::NotSquare);
    EXPECT_EQ(code(Matrix::from_rows({{1, 2}, {3, 4}})), ErrorCode::NotSymmetric);
    EXPECT_EQ(code(Matrix::from_rows({{1, 2}, {2, 1}})), ErrorCode::NotPositiveDefinite);
    EXPECT_EQ(code(Matrix::from_rows({{0}})), ErrorCode::NotPositiveDefinite);
}
