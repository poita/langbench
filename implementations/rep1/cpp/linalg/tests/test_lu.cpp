#include "test_util.hpp"

using namespace linalg;
using testutil::expect_near;

namespace {
ErrorCode code_of(const std::function<void()>& f) {
    try {
        f();
    } catch (const Error& e) {
        return e.code();
    }
    ADD_FAILURE() << "no Error thrown";
    return ErrorCode::Singular;
}
}  // namespace

TEST(LU, FactorsWithPivoting) {
    const Matrix a = Matrix::from_rows({{1, 2}, {3, 4}});
    const LU f = lu_factor(a);
    EXPECT_EQ(f.P, Matrix::from_rows({{0, 1}, {1, 0}}));
    EXPECT_EQ(f.U(0, 0), 3.0);
    EXPECT_EQ(f.U(1, 0), 0.0);
    EXPECT_EQ(f.L(0, 1), 0.0);
    EXPECT_EQ(f.L(1, 1), 1.0);
    expect_near(multiply(f.P, a), multiply(f.L, f.U), 1e-15);
}

TEST(LU, TieTakesSmallestRow) {
    const LU f = lu_factor(Matrix::from_rows({{2, 1}, {-2, 5}}));
    EXPECT_EQ(f.perm[0], 0u);
    EXPECT_EQ(f.swaps, 0);
}

TEST(LU, RandomResidual) {
    const Matrix a = testutil::random_matrix(30, 30, 1);
    const LU f = lu_factor(a);
    expect_near(multiply(f.P, a), multiply(f.L, f.U), 1e-13);
    for (std::size_t i = 0; i < 30; ++i)
        for (std::size_t j = 0; j < i; ++j) EXPECT_LE(std::fabs(f.L(i, j)), 1.0);
}

TEST(LU, Determinant) {
    EXPECT_DOUBLE_EQ(determinant(Matrix::from_rows({{1, 2}, {3, 4}})), -2.0);
}

TEST(LU, DeterminantOfSingularIsZeroAndSizeOne) {
    EXPECT_EQ(determinant(Matrix::from_rows({{1, 2}, {2, 4}})), 0.0);
    EXPECT_EQ(determinant(Matrix::from_rows({{-7}})), -7.0);
}

TEST(LU, SolveAndInverse) {
    const Matrix a = testutil::random_matrix(20, 20, 2);
    const Matrix b = testutil::random_matrix(20, 3, 3);
    expect_near(multiply(a, solve(a, b)), b, 1e-10);
    expect_near(multiply(a, inverse(a)), Matrix::identity(20), 1e-10);
}

TEST(LU, ErrorsAndTheirOrder) {
    const Matrix sing = Matrix::from_rows({{1, 2}, {2, 4}});
    EXPECT_EQ(code_of([&] { lu_factor(sing); }), ErrorCode::Singular);
    EXPECT_EQ(code_of([&] { inverse(sing); }), ErrorCode::Singular);
    EXPECT_EQ(code_of([&] { solve(sing, Matrix(2, 1)); }), ErrorCode::Singular);
    EXPECT_EQ(code_of([&] { inverse(Matrix(2, 3)); }), ErrorCode::NotSquare);
    EXPECT_EQ(code_of([&] { solve(Matrix(2, 3), Matrix(3, 1)); }), ErrorCode::NotSquare);
    EXPECT_EQ(code_of([&] { solve(Matrix::identity(2), Matrix(3, 1)); }), ErrorCode::DimensionMismatch);
}
