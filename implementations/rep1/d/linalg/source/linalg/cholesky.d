/**
 * Cholesky factorisation of symmetric positive definite matrices.
 */
module linalg.cholesky;

import std.math : sqrt;
import linalg.errors;
import linalg.matrix;

/**
 * Lower triangular `L` with positive diagonal and `A = L Lᵀ`, built column by
 * column. Only the lower triangle of `A` is read, after the symmetry check.
 *
 * Throws: `not_square`, `not_symmetric` (exact comparison), and
 *         `not_positive_definite` when a pivot `s <= 0` is met.
 */
Matrix cholesky(const Matrix a) pure
{
    enforceCode(a.isSquare, ErrorCode.not_square);
    enforceCode(a.isSymmetric, ErrorCode.not_symmetric);
    immutable n = a.rows;
    auto l = Matrix(n, n);
    auto ld = l.data;
    foreach (j; 0 .. n)
    {
        auto rowJ = ld[j * n .. j * n + j];
        double s = a.data[j * n + j];
        foreach (x; rowJ)
            s -= x * x;
        enforceCode(s > 0.0, ErrorCode.not_positive_definite);
        immutable d = sqrt(s);
        ld[j * n + j] = d;
        foreach (i; j + 1 .. n)
        {
            auto rowI = ld[i * n .. i * n + j];
            double t = a.data[i * n + j];
            foreach (k; 0 .. j)
                t -= rowI[k] * rowJ[k];
            ld[i * n + j] = t / d;
        }
    }
    return l;
}
