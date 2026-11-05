/**
 * LU factorisation with partial pivoting, and its users: determinant,
 * linear solve and inverse.
 */
module linalg.lu;

import std.math : abs;
import std.algorithm : swapRanges;
import linalg.errors;
import linalg.matrix;

/// Result of $(LREF luFactor): the packed factors and the row permutation.
struct LU
{
    /// `L` (strictly below the diagonal, unit diagonal implied) and `U`
    /// (on and above the diagonal) packed in one square matrix. When
    /// `singular` is set, only the columns before the zero pivot are final.
    Matrix packed;
    /// `perm[i]` is the index in the original matrix of the row now in row `i`.
    size_t[] perm;
    /// Number of row interchanges performed.
    int swaps;
    /// True when a pivot was exactly `0.0`.
    bool singular;

    /// The permutation matrix `P` with `P[i][perm[i]] = 1`.
    Matrix P() const pure nothrow
    {
        immutable n = perm.length;
        auto p = Matrix(n, n);
        foreach (i; 0 .. n)
            p.data[i * n + perm[i]] = 1.0;
        return p;
    }

    /// Unit lower triangular factor.
    Matrix L() const pure nothrow
    {
        immutable n = perm.length;
        auto l = Matrix(n, n);
        foreach (i; 0 .. n)
        {
            l.data[i * n .. i * n + i] = packed.data[i * n .. i * n + i];
            l.data[i * n + i] = 1.0;
        }
        return l;
    }

    /// Upper triangular factor.
    Matrix U() const pure nothrow
    {
        immutable n = perm.length;
        auto u = Matrix(n, n);
        foreach (i; 0 .. n)
            u.data[i * n + i .. (i + 1) * n] = packed.data[i * n + i .. (i + 1) * n];
        return u;
    }

    /// Determinant: product of `diag(U)` in index order, signed by swap parity.
    double determinant() const pure nothrow
    {
        if (singular)
            return 0.0;
        immutable n = perm.length;
        double d = 1.0;
        foreach (i; 0 .. n)
            d *= packed.data[i * n + i];
        return (swaps & 1) ? -d : d;
    }
}

/**
 * Factor a square matrix as `P A = L U` by right-looking Gaussian elimination
 * with partial pivoting (first row attaining the maximum magnitude wins).
 * Elimination stops at the first exactly-zero pivot and flags `singular`.
 *
 * Throws: `not_square` if `a` is not square.
 */
LU luFactor(const Matrix a) pure
{
    enforceCode(a.isSquare, ErrorCode.not_square);
    immutable n = a.rows;
    LU f;
    f.packed = a.dup;
    f.perm = new size_t[](n);
    foreach (i; 0 .. n)
        f.perm[i] = i;
    auto m = f.packed.data;

    foreach (k; 0 .. n)
    {
        size_t p = k;
        double best = abs(m[k * n + k]);
        foreach (i; k + 1 .. n)
        {
            immutable v = abs(m[i * n + k]);
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
            swapRanges(m[k * n .. (k + 1) * n], m[p * n .. (p + 1) * n]);
            immutable t = f.perm[k];
            f.perm[k] = f.perm[p];
            f.perm[p] = t;
            ++f.swaps;
        }
        immutable pivot = m[k * n + k];
        const(double)[] rowK = m[k * n + k + 1 .. (k + 1) * n];
        foreach (i; k + 1 .. n)
        {
            immutable fac = m[i * n + k] / pivot;
            m[i * n + k] = fac;
            if (fac != 0.0)
                subScaled(fac, rowK, m[i * n + k + 1 .. (i + 1) * n]);
        }
    }
    return f;
}

/// Determinant of a square matrix; `0.0` if a pivot is exactly zero.
/// Throws `not_square` for non-square input.
double determinant(const Matrix a) pure
{
    return luFactor(a).determinant;
}

/**
 * Solve `A X = B` using an existing factorisation, all right-hand sides at
 * once (row-oriented substitution; each entry sees the same operations as
 * column-by-column substitution).
 *
 * Throws: `singular` if the factorisation hit a zero pivot,
 *         `dimension_mismatch` if `b.rows` differs from the order of `A`.
 */
Matrix luSolve(const ref LU f, const Matrix b) pure
{
    immutable n = f.perm.length;
    enforceCode(!f.singular, ErrorCode.singular);
    enforceCode(b.rows == n, ErrorCode.dimension_mismatch);
    immutable k = b.cols;
    auto x = Matrix(n, k);
    foreach (i; 0 .. n)
        x.row(i)[] = b.row(f.perm[i]);
    auto lu = f.packed.data;
    foreach (i; 1 .. n)
    {
        auto xi = x.row(i);
        foreach (j; 0 .. i)
        {
            immutable l = lu[i * n + j];
            if (l != 0.0)
                subScaled(l, x.row(j), xi);
        }
    }
    foreach_reverse (i; 0 .. n)
    {
        auto xi = x.row(i);
        foreach (j; i + 1 .. n)
        {
            immutable u = lu[i * n + j];
            if (u != 0.0)
                subScaled(u, x.row(j), xi);
        }
        immutable d = lu[i * n + i];
        foreach (c; 0 .. k)
            xi[c] /= d;
    }
    return x;
}

/// Solve `A X = B`. Errors are checked in the order `not_square` (A),
/// `dimension_mismatch` (B's rows), `singular`.
Matrix solve(const Matrix a, const Matrix b)
{
    enforceCode(a.isSquare, ErrorCode.not_square);
    enforceCode(b.rows == a.rows, ErrorCode.dimension_mismatch);
    auto f = luFactor(a);
    return luSolve(f, b);
}

/// Inverse of a square matrix: `solve(A, I)`.
Matrix inverse(const Matrix a)
{
    enforceCode(a.isSquare, ErrorCode.not_square);
    return solve(a, Matrix.identity(a.rows));
}
