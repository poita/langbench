/**
 * Householder QR factorisation and least squares.
 */
module linalg.qr;

import std.math : sqrt;

import linalg.errors;
import linalg.matrix;

/// Thin QR factors of an `m x n` matrix, `m >= n`.
struct QR
{
    /// `m x n`, orthonormal columns.
    Matrix q;
    /// `n x n`, upper triangular with a non-negative diagonal.
    Matrix r;
}

/**
 * Thin Householder QR, `A = Q R`, normalised so `R` has a non-negative
 * diagonal. A zero column leaves an identity reflector, so rank-deficient
 * input is accepted.
 *
 * Throws: `dimensionMismatch` when `m < n`.
 */
QR qrDecompose(const Matrix a) @safe pure
{
    enforceCode(a.rows >= a.cols, ErrorCode.dimensionMismatch);
    const m = a.rows, n = a.cols;
    auto r = a.dup;
    auto vs = new double[][n];   // reflector k has length m - k; empty if identity

    foreach (k; 0 .. n)
    {
        auto v = new double[m - k];
        foreach (i; 0 .. m - k)
            v[i] = r.data[(k + i) * n + k];
        double ss = 0.0;
        foreach (x; v)
            ss += x * x;
        const nu = sqrt(ss);
        if (nu == 0.0)
        {
            foreach (i; k + 1 .. m)
                r.data[i * n + k] = 0.0;
            continue;
        }
        const alpha = r.data[k * n + k] >= 0.0 ? -nu : nu;
        v[0] -= alpha;
        double vv = 0.0;
        foreach (x; v)
            vv += x * x;
        const vn = sqrt(vv);
        foreach (ref x; v)
            x /= vn;

        foreach (j; k + 1 .. n)
        {
            double d = 0.0;
            foreach (i; 0 .. v.length)
                d += v[i] * r.data[(k + i) * n + j];
            const d2 = 2.0 * d;
            foreach (i; 0 .. v.length)
                r.data[(k + i) * n + j] -= d2 * v[i];
        }
        r.data[k * n + k] = alpha;
        foreach (i; k + 1 .. m)
            r.data[i * n + k] = 0.0;
        vs[k] = v;
    }

    // Q = H0 H1 ... H(n-1) applied to the first n columns of the identity.
    auto q = Matrix(m, n);
    foreach (j; 0 .. n)
        q.data[j * n + j] = 1.0;
    foreach_reverse (k; 0 .. n)
    {
        const v = vs[k];
        if (v.length == 0)
            continue;
        foreach (j; 0 .. n)
        {
            double d = 0.0;
            foreach (i; 0 .. v.length)
                d += v[i] * q.data[(k + i) * n + j];
            const d2 = 2.0 * d;
            foreach (i; 0 .. v.length)
                q.data[(k + i) * n + j] -= d2 * v[i];
        }
    }

    // Square R (top n rows), exact zeros below the diagonal, sign fix.
    auto rr = Matrix(n, n);
    foreach (i; 0 .. n)
        foreach (j; i .. n)
            rr.data[i * n + j] = r.data[i * n + j];
    foreach (j; 0 .. n)
    {
        if (rr.data[j * n + j] < 0.0)
        {
            foreach (c; j .. n)
                rr.data[j * n + c] = -rr.data[j * n + c];
            foreach (i; 0 .. m)
                q.data[i * n + j] = -q.data[i * n + j];
        }
    }
    return QR(q, rr);
}

/**
 * Least-squares solution of `A X = B` for full column rank `A`:
 * `R X = Qᵀ B` by back substitution.
 *
 * Throws: `dimensionMismatch` (`m < n`, then the rows of `B`) and
 * `singular` when `R` has an exactly zero diagonal entry.
 */
Matrix leastSquares(const Matrix a, const Matrix b) @safe pure
{
    enforceCode(a.rows >= a.cols, ErrorCode.dimensionMismatch);
    enforceCode(b.rows == a.rows, ErrorCode.dimensionMismatch);
    const f = qrDecompose(a);
    const m = a.rows, n = a.cols, k = b.cols;
    foreach (i; 0 .. n)
        enforceCode(f.r[i, i] != 0.0, ErrorCode.singular);

    auto x = Matrix(n, k);
    auto y = new double[n];
    foreach (c; 0 .. k)
    {
        foreach (j; 0 .. n)
        {
            double s = 0.0;
            foreach (i; 0 .. m)
                s += f.q[i, j] * b[i, c];
            y[j] = s;
        }
        foreach_reverse (i; 0 .. n)
        {
            double s = y[i];
            foreach (j; i + 1 .. n)
                s -= f.r[i, j] * y[j];
            y[i] = s / f.r[i, i];
        }
        foreach (i; 0 .. n)
            x[i, c] = y[i];
    }
    return x;
}

unittest
{
    import linalg.ops : mul, transpose;
    import std.math : abs;

    auto a = Matrix.fromRows([[3.0], [4.0]]);
    const f = qrDecompose(a);
    assert(abs(f.r[0, 0] - 5.0) < 1e-15);
    assert(abs(f.q[0, 0] - 0.6) < 1e-15 && abs(f.q[1, 0] - 0.8) < 1e-15);
}

unittest
{
    import linalg.ops : mul, transpose;
    import std.math : abs;

    auto a = Matrix.fromRows([[1.0, 2.0], [3.0, 4.0], [5.0, 7.0]]);
    const f = qrDecompose(a);
    const qr = mul(f.q, f.r);
    foreach (i; 0 .. a.data.length)
        assert(abs(qr.data[i] - a.data[i]) < 1e-13);
    const qtq = mul(transpose(f.q), f.q);
    foreach (i; 0 .. 2)
        foreach (j; 0 .. 2)
            assert(abs(qtq[i, j] - (i == j ? 1.0 : 0.0)) < 1e-14);
    assert(f.r[1, 0] == 0.0 && f.r[0, 0] >= 0.0 && f.r[1, 1] >= 0.0);
}

unittest
{
    import std.exception : collectException;
    import std.math : abs;

    // Fit y = 1 + 2 t through exact points.
    auto a = Matrix.fromRows([[1.0, 0.0], [1.0, 1.0], [1.0, 2.0]]);
    auto b = Matrix.fromRows([[1.0], [3.0], [5.0]]);
    const x = leastSquares(a, b);
    assert(abs(x[0, 0] - 1.0) < 1e-13 && abs(x[1, 0] - 2.0) < 1e-13);

    assert(collectException!LinAlgException(qrDecompose(Matrix(2, 3))).code
            == ErrorCode.dimensionMismatch);
    // A zero column: QR succeeds, least squares reports singular.
    auto z = Matrix.fromRows([[1.0, 0.0], [2.0, 0.0], [3.0, 0.0]]);
    qrDecompose(z);
    assert(collectException!LinAlgException(leastSquares(z, b)).code == ErrorCode.singular);
}
