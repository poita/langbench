/**
 * Symmetric eigendecomposition by the cyclic Jacobi method.
 */
module linalg.eigen;

import std.algorithm : sort;
import std.math : sqrt;
import linalg.errors;
import linalg.matrix;
import linalg.signs;

/// Eigenvalues (ascending) and matching orthonormal eigenvectors.
struct SymmetricEigen
{
    /// Eigenvalues in ascending order.
    double[] w;
    /// Column `j` is the unit eigenvector for `w[j]`, sign-normalised.
    Matrix V;
}

/// Maximum number of Jacobi sweeps.
enum maxSweeps = 60;

/**
 * Eigendecomposition `A = V diag(w) Vᵀ` of a symmetric matrix.
 *
 * Cyclic Jacobi: sweeps visit pairs `(p, q)`, `p < q`, in row-major order and
 * zero `M[p][q]` with a plane rotation. Sweeps stop when
 * `off(M) <= 1e-14 * ‖A‖F`, when `off` stops decreasing, or after 60 sweeps.
 * The eigenvector accumulator is held transposed so every rotation touches
 * contiguous rows.
 *
 * Throws: `not_square`, `not_symmetric`.
 */
SymmetricEigen symmetricEigen(const Matrix a)
{
    enforceCode(a.isSquare, ErrorCode.not_square);
    enforceCode(a.isSymmetric, ErrorCode.not_symmetric);
    immutable n = a.rows;
    auto mat = a.dup;
    auto M = mat.data;
    auto vt = Matrix.identity(n); // row j holds column j of V
    auto VT = vt.data;
    immutable phi = normFro(a);
    double prev = double.infinity;

    foreach (sweep; 0 .. maxSweeps)
    {
        double off2 = 0.0;
        foreach (i; 0 .. n)
            foreach (j; i + 1 .. n)
                off2 += M[i * n + j] * M[i * n + j];
        immutable off = sqrt(2.0 * off2);
        if (off <= 1e-14 * phi || off >= prev)
            break;
        prev = off;

        foreach (p; 0 .. n - 1)
        {
            foreach (q; p + 1 .. n)
            {
                auto Mp = M[p * n .. (p + 1) * n];
                auto Mq = M[q * n .. (q + 1) * n];
                immutable g = Mp[q];
                if (g == 0.0)
                    continue;
                immutable aa = Mp[p];
                immutable bb = Mq[q];
                immutable theta = (bb - aa) / (2.0 * g);
                immutable t = theta >= 0.0
                    ? 1.0 / (theta + sqrt(theta * theta + 1.0))
                    : -1.0 / (-theta + sqrt(theta * theta + 1.0));
                immutable c = 1.0 / sqrt(t * t + 1.0);
                immutable s = t * c;

                // Rows p and q, and (by symmetry) columns p and q. The four
                // entries of the 2x2 block written here are overwritten below.
                foreach (j; 0 .. n)
                {
                    immutable mp = Mp[j];
                    immutable mq = Mq[j];
                    immutable x = c * mp - s * mq;
                    immutable y = s * mp + c * mq;
                    Mp[j] = x;
                    Mq[j] = y;
                    M[j * n + p] = x;
                    M[j * n + q] = y;
                }
                immutable P = c * aa - s * g;
                immutable Pq = s * aa + c * g;
                immutable Qp = c * g - s * bb;
                immutable Qq = s * g + c * bb;
                Mp[p] = c * P - s * Qp;
                Mq[q] = s * Pq + c * Qq;
                Mp[q] = 0.0;
                Mq[p] = 0.0;

                auto Vp = VT[p * n .. (p + 1) * n];
                auto Vq = VT[q * n .. (q + 1) * n];
                foreach (i; 0 .. n)
                {
                    immutable x = Vp[i];
                    immutable y = Vq[i];
                    Vp[i] = c * x - s * y;
                    Vq[i] = s * x + c * y;
                }
            }
        }
    }

    auto diag = new double[](n);
    foreach (i; 0 .. n)
        diag[i] = M[i * n + i];
    auto idx = new size_t[](n);
    foreach (i; 0 .. n)
        idx[i] = i;
    idx.sort!((x, y) => diag[x] < diag[y] || (diag[x] == diag[y] && x < y));

    SymmetricEigen res;
    res.w = new double[](n);
    res.V = Matrix(n, n);
    foreach (j; 0 .. n)
    {
        res.w[j] = diag[idx[j]];
        auto col = VT[idx[j] * n .. (idx[j] + 1) * n];
        normaliseSign(col);
        foreach (i; 0 .. n)
            res.V.data[i * n + j] = col[i];
    }
    return res;
}
