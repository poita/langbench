/**
 * LU factorisation with partial pivoting, and the determinant, linear
 * solve and inverse built on it.
 */
module linalg.lu;

import std.math : abs;

import linalg.errors;
import linalg.matrix;

/// Result of `luDecompose`.
struct LU
{
    /// `L` below the diagonal (unit diagonal implied) and `U` on and above it.
    Matrix packed;
    /// `perm[i]` is the original row now sitting in row `i`.
    size_t[] perm;
    /// Number of row interchanges performed.
    size_t swaps;
    /// True when a pivot was exactly zero; elimination stopped there.
    bool singular;

    /// The permutation matrix `P` with `P[i][perm[i]] = 1`.
    Matrix permutationMatrix() const @safe pure nothrow
    {
        auto p = Matrix(perm.length, perm.length);
        foreach (i, pi; perm)
            p[i, pi] = 1.0;
        return p;
    }

    /// Unit lower triangular `L`.
    Matrix lower() const @safe pure nothrow
    {
        const n = perm.length;
        auto l = Matrix(n, n);
        foreach (i; 0 .. n)
        {
            foreach (j; 0 .. i)
                l[i, j] = packed[i, j];
            l[i, i] = 1.0;
        }
        return l;
    }

    /// Upper triangular `U`.
    Matrix upper() const @safe pure nothrow
    {
        const n = perm.length;
        auto u = Matrix(n, n);
        foreach (i; 0 .. n)
            foreach (j; i .. n)
                u[i, j] = packed[i, j];
        return u;
    }
}

/**
 * Right-looking Gaussian elimination with partial pivoting: `P A = L U`.
 *
 * The pivot is the first row with the largest magnitude in the column.
 * A zero pivot does not throw: it sets `singular` and stops, so callers can
 * decide (`determinant` returns zero, `lu` reports `singular`).
 *
 * Throws: `notSquare`.
 */
LU luDecompose(const Matrix a) @safe pure
{
    enforceCode(a.isSquare, ErrorCode.notSquare);
    const n = a.rows;
    auto f = LU(a.dup, new size_t[n], 0, false);
    foreach (i; 0 .. n)
        f.perm[i] = i;
    auto m = f.packed.data;

    foreach (k; 0 .. n)
    {
        size_t p = k;
        double best = abs(m[k * n + k]);
        foreach (i; k + 1 .. n)
        {
            const v = abs(m[i * n + k]);
            if (v > best)
            {
                best = v;
                p = i;
            }
        }
        if (best == 0.0)
        {
            f.singular = true;
            return f;
        }
        if (p != k)
        {
            foreach (j; 0 .. n)
            {
                const t = m[k * n + j];
                m[k * n + j] = m[p * n + j];
                m[p * n + j] = t;
            }
            const t = f.perm[k];
            f.perm[k] = f.perm[p];
            f.perm[p] = t;
            ++f.swaps;
        }
        const pivot = m[k * n + k];
        const rowk = m[k * n + k + 1 .. (k + 1) * n];
        foreach (i; k + 1 .. n)
        {
            const fac = m[i * n + k] / pivot;
            m[i * n + k] = fac;
            auto rowi = m[i * n + k + 1 .. (i + 1) * n];
            foreach (j; 0 .. rowi.length)
                rowi[j] -= fac * rowk[j];
        }
    }
    return f;
}

/// `luDecompose` that throws `singular` on a zero pivot.
LU luFactor(const Matrix a) @safe pure
{
    auto f = luDecompose(a);
    enforceCode(!f.singular, ErrorCode.singular);
    return f;
}

/**
 * Determinant: product of `U`'s diagonal in increasing order, signed by the
 * parity of the row swaps; exactly `0.0` for a singular matrix.
 *
 * Throws: `notSquare`.
 */
double determinant(const Matrix a) @safe pure
{
    const f = luDecompose(a);
    if (f.singular)
        return 0.0;
    const n = a.rows;
    double d = 1.0;
    foreach (i; 0 .. n)
        d *= f.packed[i, i];
    return (f.swaps & 1) ? -d : d;
}

/// Solves `A X = B` using an existing factorisation of `A`.
Matrix luSolve(const LU f, const Matrix b) @safe pure
{
    const n = f.perm.length;
    enforceCode(b.rows == n, ErrorCode.dimensionMismatch);
    const k = b.cols;
    auto x = Matrix(n, k);
    auto y = new double[n];
    foreach (c; 0 .. k)
    {
        foreach (i; 0 .. n)
        {
            double s = b[f.perm[i], c];
            foreach (j; 0 .. i)
                s -= f.packed[i, j] * y[j];
            y[i] = s;
        }
        foreach_reverse (i; 0 .. n)
        {
            double s = y[i];
            foreach (j; i + 1 .. n)
                s -= f.packed[i, j] * y[j];
            y[i] = s / f.packed[i, i];
        }
        foreach (i; 0 .. n)
            x[i, c] = y[i];
    }
    return x;
}

/**
 * Solves `A X = B`.
 *
 * Throws: `notSquare`, then `dimensionMismatch` (rows of `B`), then `singular`.
 */
Matrix solve(const Matrix a, const Matrix b) @safe pure
{
    enforceCode(a.isSquare, ErrorCode.notSquare);
    enforceCode(b.rows == a.rows, ErrorCode.dimensionMismatch);
    return luSolve(luFactor(a), b);
}

/// `A⁻¹`, computed as `solve(A, I)`. Throws `notSquare` or `singular`.
Matrix inverse(const Matrix a) @safe pure
{
    enforceCode(a.isSquare, ErrorCode.notSquare);
    return solve(a, Matrix.identity(a.rows));
}

version (unittest)
{
    import linalg.ops : mul;

    private bool close(const Matrix a, const Matrix b, double tol = 1e-12)
    {
        if (a.rows != b.rows || a.cols != b.cols)
            return false;
        foreach (i; 0 .. a.data.length)
            if (abs(a.data[i] - b.data[i]) > tol)
                return false;
        return true;
    }
}

unittest
{
    auto a = Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]]);
    assert(determinant(a) == -2.0);
    const f = luFactor(a);
    assert(f.perm == [1, 0]);
    assert(f.upper[0, 0] == 3.0 && f.upper[1, 0] == 0.0);
    assert(close(mul(f.permutationMatrix, a), mul(f.lower, f.upper)));
}

unittest
{
    auto a = Matrix.fromRows([[4.0, 3.0, 2.0], [1.0, 3.0, 1.0], [2.0, 1.0, 5.0]]);
    assert(close(mul(a, inverse(a)), Matrix.identity(3)));
    auto b = Matrix.fromRows([[1.0], [2.0], [3.0]]);
    assert(close(mul(a, solve(a, b)), b));
    // Ties go to the smallest row index.
    auto t = Matrix.fromRows([[1.0, 0.0], [-1.0, 1.0]]);
    assert(luFactor(t).perm == [0, 1]);
}

unittest
{
    import std.exception : collectException;

    auto s = Matrix.fromRows([[1.0, 2.0], [2.0, 4.0]]);
    assert(determinant(s) == 0.0);
    assert(collectException!LinAlgException(luFactor(s)).code == ErrorCode.singular);
    assert(collectException!LinAlgException(inverse(s)).code == ErrorCode.singular);
    assert(collectException!LinAlgException(determinant(Matrix(2, 3))).code
            == ErrorCode.notSquare);
    // not_square is reported before dimension_mismatch
    assert(collectException!LinAlgException(solve(Matrix(2, 3), Matrix(3, 1))).code
            == ErrorCode.notSquare);
    assert(collectException!LinAlgException(solve(Matrix.identity(2), Matrix(3, 1))).code
            == ErrorCode.dimensionMismatch);
}
