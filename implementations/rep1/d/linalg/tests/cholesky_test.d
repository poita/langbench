module tests.cholesky_test;

import linalg;
import tests.helpers;

unittest // worked example
{
    auto s = Matrix.fromRows([[4.0, 2.0], [2.0, 5.0]]);
    auto l = cholesky(s);
    assert(close(l, Matrix.fromRows([[2.0, 0.0], [1.0, 2.0]])));
}

unittest // L Lᵀ = A for an SPD matrix
{
    auto b = pseudoRandom(9, 9, 3);
    auto a = multiply(transpose(b), b);
    foreach (i; 0 .. 9)
        a[i, i] = a[i, i] + 1.0;
    auto l = cholesky(a);
    assert(close(multiply(l, transpose(l)), a, 1e-12));
    foreach (i; 0 .. 9)
    {
        assert(l[i, i] > 0);
        foreach (j; i + 1 .. 9)
            assert(l[i, j] == 0.0);
    }
}

unittest // errors, in precedence order
{
    assertCode(ErrorCode.not_square, { cholesky(Matrix(2, 3)); });
    assertCode(ErrorCode.not_symmetric, { cholesky(Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]])); });
    assertCode(ErrorCode.not_positive_definite, { cholesky(Matrix.fromRows([[1.0, 2.0], [2.0, 1.0]])); });
    assertCode(ErrorCode.not_positive_definite, { cholesky(Matrix(2, 2)); });
}
