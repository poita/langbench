module tests.qr_test;

import linalg;
import tests.helpers;

unittest // sign normalisation example
{
    auto a = Matrix.fromRows([[3.0], [4.0]]);
    auto f = qrFactor(a);
    assert(close(f.Q, Matrix.fromRows([[0.6], [0.8]])));
    assert(close(f.R, Matrix.fromRows([[5.0]])));
}

unittest // A = Q R, Q'Q = I, R upper triangular with non-negative diagonal
{
    foreach (dims; [[8, 8], [10, 4], [5, 1], [3, 3]])
    {
        auto a = pseudoRandom(dims[0], dims[1], cast(uint) dims[0] * 31 + dims[1]);
        auto f = qrFactor(a);
        assert(f.Q.rows == a.rows && f.Q.cols == a.cols);
        assert(f.R.rows == a.cols && f.R.cols == a.cols);
        assert(close(multiply(f.Q, f.R), a, 1e-13));
        assert(close(multiply(transpose(f.Q), f.Q), Matrix.identity(a.cols), 1e-13));
        foreach (i; 0 .. f.R.rows)
        {
            assert(f.R[i, i] >= 0);
            foreach (j; 0 .. i)
                assert(f.R[i, j] == 0.0);
        }
    }
}

unittest // rank deficient input still factors
{
    auto a = Matrix.fromRows([[1.0, 2.0], [2.0, 4.0], [3.0, 6.0]]);
    auto f = qrFactor(a);
    assert(close(multiply(f.Q, f.R), a, 1e-13));
    auto z = Matrix.fromRows([[0.0, 1.0], [0.0, 2.0]]); // zero first column
    auto g = qrFactor(z);
    assert(close(multiply(g.Q, g.R), z, 1e-13));
}

unittest // errors
{
    assertCode(ErrorCode.dimension_mismatch, { qrFactor(Matrix(2, 3)); });
    assertCode(ErrorCode.dimension_mismatch, { leastSquares(Matrix(2, 3), Matrix(2, 1)); });
    assertCode(ErrorCode.dimension_mismatch, { leastSquares(Matrix(3, 2), Matrix(2, 1)); });
    auto lowRank = Matrix.fromRows([[0.0, 1.0], [0.0, 2.0], [0.0, 3.0]]); // zero column
    assertCode(ErrorCode.singular, { leastSquares(lowRank, Matrix(3, 1)); });
}

unittest // least squares: fit y = c0 + c1 x
{
    auto a = Matrix.fromRows([[1.0, 0.0], [1.0, 1.0], [1.0, 2.0], [1.0, 3.0]]);
    auto b = Matrix.fromRows([[1.0], [3.0], [5.0], [7.0]]); // exactly 1 + 2x
    auto x = leastSquares(a, b);
    assert(close(x, Matrix.fromRows([[1.0], [2.0]]), 1e-12));
    // Noisy data: normal equations hold, Aᵀ(Ax - b) = 0.
    auto b2 = Matrix.fromRows([[1.0], [2.0], [5.0], [8.0]]);
    auto x2 = leastSquares(a, b2);
    auto resid = Matrix(4, 1);
    auto ax = multiply(a, x2);
    foreach (i; 0 .. 4)
        resid[i, 0] = ax[i, 0] - b2[i, 0];
    assert(close(multiply(transpose(a), resid), Matrix(2, 1), 1e-12));
}
