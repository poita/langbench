module tests.lu_test;

import std.math : isClose;
import linalg;
import tests.helpers;

unittest // worked example from the specification
{
    auto a = Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]]);
    auto f = luFactor(a);
    assert(!f.singular && f.swaps == 1);
    assert(f.perm == [1, 0]);
    assert(f.P.data == [0.0, 1, 1, 0]);
    assert(f.U[0, 0] == 3 && f.U[0, 1] == 4 && f.U[1, 0] == 0);
    assert(f.L[0, 1] == 0 && f.L[0, 0] == 1 && f.L[1, 1] == 1);
    assert(close(f.U, Matrix.fromRows([[3.0, 4.0], [0.0, 2.0 / 3.0]])));
    assert(isClose(determinant(a), -2.0));
}

unittest // P A = L U on a random matrix
{
    auto a = pseudoRandom(12, 12);
    auto f = luFactor(a);
    assert(close(multiply(f.P, a), multiply(f.L, f.U), 1e-13));
    foreach (i; 0 .. 12)
        foreach (j; 0 .. i)
            assert(f.L[i, j] <= 1.0 && f.L[i, j] >= -1.0);
}

unittest // tie in the pivot column resolves to the smallest row index
{
    auto a = Matrix.fromRows([[2.0, 1.0], [-2.0, 3.0]]);
    auto f = luFactor(a);
    assert(f.perm == [0, 1] && f.swaps == 0);
}

unittest // singular matrices
{
    auto s = Matrix.fromRows([[1.0, 2.0], [2.0, 4.0]]);
    assert(luFactor(s).singular);
    assert(determinant(s) == 0.0);
    assertCode(ErrorCode.singular, { inverse(s); });
    assertCode(ErrorCode.singular, { solve(s, Matrix.identity(2)); });
    assert(determinant(Matrix.fromRows([[0.0, 0.0], [0.0, 0.0]])) == 0.0);
}

unittest // shape errors and their precedence
{
    auto r = Matrix(2, 3);
    assertCode(ErrorCode.not_square, { luFactor(r); });
    assertCode(ErrorCode.not_square, { determinant(r); });
    assertCode(ErrorCode.not_square, { inverse(r); });
    // A is checked before B's row count.
    assertCode(ErrorCode.not_square, { solve(r, Matrix(3, 1)); });
    assertCode(ErrorCode.dimension_mismatch, { solve(Matrix.identity(2), Matrix(3, 1)); });
}

unittest // solve and inverse
{
    auto a = pseudoRandom(15, 15, 7);
    auto b = pseudoRandom(15, 3, 8);
    auto x = solve(a, b);
    assert(x.rows == 15 && x.cols == 3);
    assert(close(multiply(a, x), b, 1e-9));
    auto inv = inverse(a);
    assert(close(multiply(a, inv), Matrix.identity(15), 1e-9));
}

unittest // 1x1
{
    auto a = Matrix.fromRows([[4.0]]);
    assert(determinant(a) == 4.0);
    assert(inverse(a)[0, 0] == 0.25);
}
