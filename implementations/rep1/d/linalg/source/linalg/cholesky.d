/**
 * Cholesky factorisation of symmetric positive definite matrices.
 */
module linalg.cholesky;

import std.math : sqrt;

import linalg.errors;
import linalg.matrix;
import linalg.ops : isSymmetric;

/**
 * Lower triangular `L` with a positive diagonal such that `A = L Lᵀ`,
 * computed column by column.
 *
 * Throws: `notSquare`, `notSymmetric`, then `notPositiveDefinite` when a
 * pivot `s <= 0`.
 */
Matrix cholesky(const Matrix a) @safe pure
{
    enforceCode(a.isSquare, ErrorCode.notSquare);
    enforceCode(isSymmetric(a), ErrorCode.notSymmetric);
    const n = a.rows;
    auto l = Matrix(n, n);
    foreach (j; 0 .. n)
    {
        double s = a.data[j * n + j];
        foreach (k; 0 .. j)
            s -= l.data[j * n + k] * l.data[j * n + k];
        enforceCode(s > 0.0, ErrorCode.notPositiveDefinite);
        const d = sqrt(s);
        l.data[j * n + j] = d;
        foreach (i; j + 1 .. n)
        {
            double t = a.data[i * n + j];
            foreach (k; 0 .. j)
                t -= l.data[i * n + k] * l.data[j * n + k];
            l.data[i * n + j] = t / d;
        }
    }
    return l;
}

unittest
{
    auto a = Matrix.fromRows([[4.0, 2.0], [2.0, 5.0]]);
    assert(cholesky(a) == Matrix.fromRows([[2.0, 0.0], [1.0, 2.0]]));
}

unittest
{
    import std.exception : collectException;

    assert(collectException!LinAlgException(cholesky(Matrix(2, 3))).code == ErrorCode.notSquare);
    assert(collectException!LinAlgException(cholesky(Matrix.fromRows([[1.0, 2.0], [3.0, 1.0]]))).code
            == ErrorCode.notSymmetric);
    assert(collectException!LinAlgException(cholesky(Matrix.fromRows([[1.0, 2.0], [2.0, 1.0]]))).code
            == ErrorCode.notPositiveDefinite);
}
