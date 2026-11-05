module tests.svd_test;

import std.math : isClose, sqrt;
import linalg;
import tests.helpers;

private Matrix reconstruct(const SVD f)
{
    auto us = f.U.dup;
    foreach (i; 0 .. us.rows)
        foreach (j; 0 .. us.cols)
            us[i, j] = f.U[i, j] * f.s[j];
    return multiply(us, transpose(f.V));
}

unittest // reconstruction and orthonormality for tall, wide and square shapes
{
    foreach (dims; [[7, 7], [9, 4], [4, 9], [6, 1], [1, 6], [1, 1]])
    {
        auto a = pseudoRandom(dims[0], dims[1], cast(uint) (dims[0] * 17 + dims[1]));
        auto f = svd(a);
        immutable k = dims[0] < dims[1] ? dims[0] : dims[1];
        assert(f.U.rows == dims[0] && f.U.cols == k);
        assert(f.V.rows == dims[1] && f.V.cols == k);
        assert(f.s.length == k);
        assert(close(reconstruct(f), a, 1e-12));
        assert(close(multiply(transpose(f.U), f.U), Matrix.identity(k), 1e-12));
        assert(close(multiply(transpose(f.V), f.V), Matrix.identity(k), 1e-12));
        foreach (j; 1 .. k)
            assert(f.s[j - 1] >= f.s[j]);
        assert(f.s[k - 1] >= 0);
    }
}

unittest // known singular values and sign convention
{
    auto a = Matrix.fromRows([[3.0, 0.0], [0.0, -2.0]]);
    auto f = svd(a);
    assert(isClose(f.s[0], 3.0) && isClose(f.s[1], 2.0));
    foreach (j; 0 .. 2) // largest entry of each U column is positive
    {
        double[] col = [f.U[0, j], f.U[1, j]];
        assert(col[argMaxAbs(col)] > 0);
    }
    assert(close(reconstruct(f), a));
}

unittest // singularValues agrees with svd; condition number
{
    auto a = pseudoRandom(8, 5, 5);
    auto s = singularValues(a);
    auto f = svd(a);
    foreach (j; 0 .. 5)
        assert(s[j] == f.s[j]);
    assert(conditionNumber(a) == s[0] / s[4]);
    assert(isClose(conditionNumber(Matrix.fromRows([[4.0, 0.0], [0.0, 2.0]])), 2.0));
    assert(isClose(conditionNumber(Matrix.identity(5)), 1.0));
}

unittest // zero singular value
{
    auto a = Matrix.fromRows([[1.0, 2.0], [2.0, 4.0]]);
    // rank one: either exactly singular or astronomically ill-conditioned
    auto s = singularValues(a);
    assert(s[1] <= 1e-15 * s[0]);
    assertCode(ErrorCode.singular, { conditionNumber(Matrix(3, 2)); });
}
