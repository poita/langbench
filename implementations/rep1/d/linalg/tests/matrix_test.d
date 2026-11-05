module tests.matrix_test;

import std.math : sqrt, isClose;
import linalg;
import tests.helpers;

unittest // construction and indexing
{
    auto a = Matrix.fromRows([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]);
    assert(a.rows == 2 && a.cols == 3);
    assert(a[1, 2] == 6);
    a[0, 0] = 9;
    assert(a.row(0) == [9.0, 2, 3]);
    auto b = a.dup;
    b[0, 0] = 1;
    assert(a[0, 0] == 9);
    assert(Matrix.identity(3).isSymmetric);
    assert(!a.isSquare);
}

unittest // add
{
    auto a = Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]]);
    auto b = Matrix.fromRows([[0.5, 0.0], [0.0, -1.5]]);
    assert(add(a, b).data == [1.5, 2, 3, 2.5]);
    assertCode(ErrorCode.dimension_mismatch, { add(a, Matrix(2, 3)); });
}

unittest // multiply
{
    auto a = Matrix.fromRows([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]);
    auto b = Matrix.fromRows([[7.0, 8.0], [9.0, 10.0], [11.0, 12.0]]);
    auto c = multiply(a, b);
    assert(c.rows == 2 && c.cols == 2);
    assert(c.data == [58.0, 64, 139, 154]);
    assertCode(ErrorCode.dimension_mismatch, { multiply(a, a); });
    assert(multiply(Matrix.identity(2), c) == c);
}

unittest // transpose
{
    auto a = Matrix.fromRows([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]);
    auto t = transpose(a);
    assert(t.rows == 3 && t.cols == 2);
    assert(t.data == [1.0, 4, 2, 5, 3, 6]);
    assert(transpose(t) == a);
}

unittest // norms
{
    auto a = Matrix.fromRows([[1.0, -2.0], [-3.0, 4.0]]);
    assert(norm1(a) == 6);   // column sums 4, 6
    assert(normInf(a) == 7); // row sums 3, 7
    assert(isClose(normFro(a), sqrt(30.0)));
    auto r = Matrix.fromRows([[1.0, -5.0, 2.0]]);
    assert(norm1(r) == 5 && normInf(r) == 8);
}
