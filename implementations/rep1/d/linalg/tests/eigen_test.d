module tests.eigen_test;

import std.math : isClose, sqrt;
import linalg;
import tests.helpers;

unittest // worked example: ascending eigenvalues, sign-normalised vectors
{
    auto a = Matrix.fromRows([[2.0, 1.0], [1.0, 3.0]]);
    auto e = symmetricEigen(a);
    assert(isClose(e.w[0], (5 - sqrt(5.0)) / 2));
    assert(isClose(e.w[1], (5 + sqrt(5.0)) / 2));
    assert(close(e.V, Matrix.fromRows([[0.8506508083520399, 0.5257311121191336],
                                       [-0.5257311121191336, 0.8506508083520399]]), 1e-12));
}

unittest // A V = V diag(w), VᵀV = I
{
    auto b = pseudoRandom(14, 14, 99);
    auto a = add(b, transpose(b));
    auto e = symmetricEigen(a);
    auto av = multiply(a, e.V);
    auto vd = e.V.dup;
    foreach (i; 0 .. 14)
        foreach (j; 0 .. 14)
            vd[i, j] = e.V[i, j] * e.w[j];
    assert(close(av, vd, 1e-12));
    assert(close(multiply(transpose(e.V), e.V), Matrix.identity(14), 1e-12));
    foreach (j; 1 .. 14)
        assert(e.w[j - 1] <= e.w[j]);
    foreach (j; 0 .. 14)
    {
        auto col = Matrix(14, 1);
        foreach (i; 0 .. 14)
            col[i, 0] = e.V[i, j];
        assert(col.data[argMaxAbs(col.data)] > 0);
    }
}

unittest // diagonal input needs no rotation but must still be sorted
{
    auto a = Matrix.fromRows([[3.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 2.0]]);
    auto e = symmetricEigen(a);
    assert(e.w == [1.0, 2, 3]);
    assert(e.V.data == [0.0, 0, 1, 1, 0, 0, 0, 1, 0]);
}

unittest // 1x1 and errors
{
    auto e = symmetricEigen(Matrix.fromRows([[-4.0]]));
    assert(e.w == [-4.0] && e.V[0, 0] == 1.0);
    assertCode(ErrorCode.not_square, { symmetricEigen(Matrix(2, 3)); });
    assertCode(ErrorCode.not_symmetric, { symmetricEigen(Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]])); });
}
