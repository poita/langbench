/**
 * Householder QR factorisation and linear least squares.
 */
module linalg.qr;

import std.math : sqrt;
import linalg.errors;
import linalg.matrix;

/// Thin QR factors of an `m x n` matrix (`m >= n`).
struct QR
{
    /// `m x n`, orthonormal columns.
    Matrix Q;
    /// `n x n`, upper triangular with a non-negative diagonal.
    Matrix R;
}

/**
 * Thin Householder QR, `A = Q R`, normalised so that `diag(R) >= 0`.
 *
 * A column that is exactly zero from the diagonal down gets an identity
 * reflector, so rank-deficient matrices factor fine.
 *
 * Throws: `dimension_mismatch` if `a.rows < a.cols`.
 */
QR qrFactor(const Matrix a) pure
{
    enforceCode(a.rows >= a.cols, ErrorCode.dimension_mismatch);
    immutable m = a.rows, n = a.cols;
    auto r = a.dup;
    auto rd = r.data;
    auto vs = new double[][](n);
    auto w = new double[](n);

    foreach (k; 0 .. n)
    {
        double ss = 0.0;
        foreach (i; k .. m)
            ss += rd[i * n + k] * rd[i * n + k];
        immutable nu = sqrt(ss);
        if (nu == 0.0)
        {
            foreach (i; k + 1 .. m)
                rd[i * n + k] = 0.0;
            continue;
        }
        immutable alpha = rd[k * n + k] >= 0.0 ? -nu : nu;
        auto v = new double[](m - k);
        foreach (i; k .. m)
            v[i - k] = rd[i * n + k];
        v[0] -= alpha;
        double vv = 0.0;
        foreach (x; v)
            vv += x * x;
        immutable vn = sqrt(vv);
        foreach (ref x; v)
            x /= vn;
        vs[k] = v;

        // w[j] = v . R[k.., j] for j > k, accumulated row by row.
        auto wk = w[k + 1 .. n];
        wk[] = 0.0;
        foreach (i; k .. m)
            axpy(v[i - k], rd[i * n + k + 1 .. (i + 1) * n], wk);
        foreach (ref x; wk)
            x *= 2.0;
        foreach (i; k .. m)
            subScaled(v[i - k], wk, rd[i * n + k + 1 .. (i + 1) * n]);

        rd[k * n + k] = alpha;
        foreach (i; k + 1 .. m)
            rd[i * n + k] = 0.0;
    }

    // Q from the first n columns of the identity, reflectors in reverse order.
    auto q = Matrix(m, n);
    foreach (i; 0 .. n)
        q.data[i * n + i] = 1.0;
    auto qd = q.data;
    foreach_reverse (k; 0 .. n)
    {
        auto v = vs[k];
        if (v is null)
            continue;
        auto wk = w[k .. n];
        wk[] = 0.0;
        foreach (i; k .. m)
            axpy(v[i - k], qd[i * n + k .. (i + 1) * n], wk);
        foreach (ref x; wk)
            x *= 2.0;
        foreach (i; k .. m)
            subScaled(v[i - k], wk, qd[i * n + k .. (i + 1) * n]);
    }

    // Keep the top n x n block of R and force a non-negative diagonal.
    auto rr = Matrix(n, n);
    rr.data[] = rd[0 .. n * n];
    foreach (j; 0 .. n)
    {
        if (rr.data[j * n + j] < 0.0)
        {
            foreach (c; 0 .. n)
                rr.data[j * n + c] = -rr.data[j * n + c];
            foreach (i; 0 .. m)
                qd[i * n + j] = -qd[i * n + j];
        }
    }
    return QR(q, rr);
}

/**
 * Least-squares solution of `A X = B` for full-column-rank `A` (`m >= n`):
 * `R X = Qᵀ B` by back substitution.
 *
 * Throws: `dimension_mismatch` (`m < n`, or `b.rows != m`), `singular`
 *         (an exactly zero diagonal entry of `R`).
 */
Matrix leastSquares(const Matrix a, const Matrix b)
{
    enforceCode(a.rows >= a.cols, ErrorCode.dimension_mismatch);
    enforceCode(b.rows == a.rows, ErrorCode.dimension_mismatch);
    immutable m = a.rows, n = a.cols, k = b.cols;
    auto f = qrFactor(a);
    foreach (j; 0 .. n)
        enforceCode(f.R.data[j * n + j] != 0.0, ErrorCode.singular);

    auto y = Matrix(n, k);
    foreach (i; 0 .. m)
    {
        auto bi = b.row(i);
        foreach (j; 0 .. n)
        {
            immutable q = f.Q.data[i * n + j];
            if (q != 0.0)
                axpy(q, bi, y.row(j));
        }
    }
    foreach_reverse (i; 0 .. n)
    {
        auto yi = y.row(i);
        foreach (j; i + 1 .. n)
        {
            immutable u = f.R.data[i * n + j];
            if (u != 0.0)
                subScaled(u, y.row(j), yi);
        }
        immutable d = f.R.data[i * n + i];
        foreach (c; 0 .. k)
            yi[c] /= d;
    }
    return y;
}
