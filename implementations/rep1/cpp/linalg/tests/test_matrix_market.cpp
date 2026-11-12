#include "test_util.hpp"

using namespace linalg;

TEST(MatrixMarket, ArrayGeneralIsColumnMajor) {
    const Matrix m = parse_matrix_market(
        "%%MatrixMarket matrix array real general\n% comment\n2 2\n1.0\n3.0\n2.0\n4.0\n");
    EXPECT_EQ(m, Matrix::from_rows({{1, 2}, {3, 4}}));
}

TEST(MatrixMarket, CoordinateGeneralAndPattern) {
    EXPECT_EQ(parse_matrix_market("%%MatrixMarket matrix coordinate real general\n2 2 2\n2 2 -1.5\n1 1 0.5\n"),
              Matrix::from_rows({{0.5, 0}, {0, -1.5}}));
    EXPECT_EQ(parse_matrix_market("%%MatrixMarket MATRIX Coordinate Pattern General\n\n2 3 2\n1 3\n\n2 1\n"),
              Matrix::from_rows({{0, 0, 1}, {1, 0, 0}}));
}

TEST(MatrixMarket, SymmetricAndSkewCoordinate) {
    EXPECT_EQ(parse_matrix_market("%%MatrixMarket matrix coordinate real symmetric\n2 2 3\n1 1 4\n2 1 2\n2 2 5\n"),
              Matrix::from_rows({{4, 2}, {2, 5}}));
    EXPECT_EQ(parse_matrix_market("%%MatrixMarket matrix coordinate integer skew-symmetric\n3 3 2\n2 1 7\n3 1 -2\n"),
              Matrix::from_rows({{0, -7, 2}, {7, 0, 0}, {-2, 0, 0}}));
}

TEST(MatrixMarket, SymmetricAndSkewArray) {
    EXPECT_EQ(parse_matrix_market("%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n"),
              Matrix::from_rows({{4, 2}, {2, 5}}));
    EXPECT_EQ(parse_matrix_market("%%MatrixMarket matrix array real skew-symmetric\n3 3\n1\n2\n3\n"),
              Matrix::from_rows({{0, -1, -2}, {1, 0, -3}, {2, 3, 0}}));
}

TEST(MatrixMarket, ExponentForms) {
    const Matrix m = parse_matrix_market("%%MatrixMarket matrix array real general\n1 3\n3.0e-7\n1.0E+03\n-2.5\n");
    EXPECT_EQ(m(0, 0), 3.0e-7);
    EXPECT_EQ(m(0, 1), 1000.0);
    EXPECT_EQ(m(0, 2), -2.5);
}

TEST(MatrixMarket, RejectsBadBanner) {
    EXPECT_THROW(parse_matrix_market("hello\n1 1\n1\n"), ParseError);
}

TEST(MatrixMarket, WriterFormat) {
    EXPECT_EQ(format_value(-0.0), "0.0000000000e+00");
    EXPECT_EQ(format_value(1.2345678901), "1.2345678901e+00");
    EXPECT_EQ(format_value(-7e-3), "-7.0000000000e-03");
    EXPECT_EQ(format_value(1e100), "1.0000000000e+100");
    EXPECT_EQ(to_matrix_market(Matrix::from_rows({{1, 2}, {3, 4}})),
              "%%MatrixMarket matrix array real general\n2 2\n"
              "1.0000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n4.0000000000e+00\n");
}
