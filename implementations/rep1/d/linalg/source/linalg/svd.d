/**
 * Singular value decomposition by one-sided (Hestenes) Jacobi, and the
 * condition number derived from it.
 */
module linalg.svd;

import std.algorithm : sort;
import std.math : sqrt;
import linalg.errors;
import linalg.matrix;
import linalg.signs;

/// Thin SVD `A = U diag(s) Vᵀ`, with `k = min(m, n)`.
struct SVD
{
    /// `m x k`, orthonormal columns, sign-normalised.
    Matrix U;
    /// `k` singular values, descending, non-negative.
    double[] s;
    /// `n x k`, orthonormal columns.
    Matrix V;
}

/// Maximum number of Jacobi sweeps.
enum maxSweeps = 60;

/// Columns of the working matrix (and optionally of V) after convergence.
private struct Jacobi
{
    size_t rows;     // length of every column of W
    size_t cols;     // number of columns
    double[] W;      // cols columns, each contiguous, length rows
    double[] V;      // cols columns of length cols, or empty when not wanted

    double[] wcol(size_t j) pure nothrow @nogc
    {
        return W[j * rows .. (j + 1) * rows];
    }
}

/// Build the working set from `a` (or from `aᵀ` when `a.rows < a.cols`).
private Jacobi makeWorkingSet(const Matrix a, bool wantV) pure nothrow
{
    Jacobi j;
    immutable tall = a.rows >= a.cols;
    j.rows = tall ? a.rows : a.cols;
    j.cols = tall ? a.cols : a.rows;
    j.W = new double[](j.rows * j.cols);
    if (tall)
    {
        foreach (c; 0 .. j.cols)
            foreach (i; 0 .. j.rows)
                j.W[c * j.rows + i] = a.data[i * a.cols + c];
    }
    else
    {
        foreach (c; 0 .. j.cols) // column c of Aᵀ is row c of A
            j.W[c * j.rows .. (c + 1) * j.rows] = a.data[c * a.cols .. (c + 1) * a.cols];
    }
    if (wantV)
    {
        j.V = new double[](j.cols * j.cols);
        j.V[] = 0.0;
        foreach (c; 0 .. j.cols)
            j.V[c * j.cols + c] = 1.0;
    }
    return j;
}

/// Run Jacobi sweeps until a whole sweep rotates nothing (or 60 sweeps).
private void sweep(ref Jacobi j) pure nothrow @nogc
{
    immutable m = j.rows, n = j.cols;
    foreach (iter; 0 .. maxSweeps)
    {
        bool rotated = false;
        foreach (p; 0 .. n - 1)
        {
            foreach (q; p + 1 .. n)
            {
                auto wp = j.wcol(p);
                auto wq = j.wcol(q);
                double alpha = 0.0, beta = 0.0, gamma = 0.0;
                foreach (i; 0 .. m)
                {
                    immutable x = wp[i];
                    immutable y = wq[i];
                    alpha += x * x;
                    beta += y * y;
                    gamma += x * y;
                }
                if (gamma == 0.0 || alpha == 0.0 || beta == 0.0)
                    continue;
                immutable ag = gamma < 0 ? -gamma : gamma;
                if (ag <= 1e-14 * sqrt(alpha * beta))
                    continue;
                immutable zeta = (beta - alpha) / (2.0 * gamma);
                immutable t = zeta >= 0.0
                    ? 1.0 / (zeta + sqrt(zeta * zeta + 1.0))
                    : -1.0 / (-zeta + sqrt(zeta * zeta + 1.0));
                immutable c = 1.0 / sqrt(t * t + 1.0);
                immutable s = t * c;
                rotate(wp, wq, c, s);
                if (j.V.length)
                    rotate(j.V[p * n .. (p + 1) * n], j.V[q * n .. (q + 1) * n], c, s);
                rotated = true;
            }
        }
        if (!rotated)
            break;
    }
}

private void rotate(double[] p, double[] q, double c, double s) pure nothrow @nogc
{
    foreach (i; 0 .. p.length)
    {
        immutable x = p[i];
        immutable y = q[i];
        p[i] = c * x - s * y;
        q[i] = s * x + c * y;
    }
}

private double columnNorm(const(double)[] v) pure nothrow @nogc
{
    double s = 0.0;
    foreach (x; v)
        s += x * x;
    return sqrt(s);
}

/// Indices `0 .. n` sorted by `key` descending, ties by smaller index.
private size_t[] descendingOrder(const(double)[] key) pure
{
    auto idx = new size_t[](key.length);
    foreach (i; 0 .. idx.length)
        idx[i] = i;
    idx.sort!((x, y) => key[x] > key[y] || (key[x] == key[y] && x < y));
    return idx;
}

/**
 * Thin SVD of any `m x n` matrix. For `m < n` the algorithm runs on `Aᵀ` and
 * the roles of `U` and `V` are swapped. Signs are fixed on `U`'s columns
 * (with `V`'s columns following), see `linalg.signs`.
 */
SVD svd(const Matrix a)
{
    auto j = makeWorkingSet(a, true);
    sweep(j);
    immutable k = j.cols, mw = j.rows;
    auto sigma = new double[](k);
    foreach (c; 0 .. k)
        sigma[c] = columnNorm(j.wcol(c));
    auto order = descendingOrder(sigma);

    SVD res;
    res.s = new double[](k);
    auto left = Matrix(mw, k);  // normalised columns of W
    auto right = Matrix(k, k);  // columns of the V accumulator
    foreach (c; 0 .. k)
    {
        immutable src = order[c];
        immutable sg = sigma[src];
        res.s[c] = sg;
        auto w = j.wcol(src);
        if (sg != 0.0)
            foreach (i; 0 .. mw)
                left.data[i * k + c] = w[i] / sg;
        foreach (i; 0 .. k)
            right.data[i * k + c] = j.V[src * k + i];
    }
    if (a.rows >= a.cols)
    {
        res.U = left;
        res.V = right;
    }
    else
    {
        res.U = right;
        res.V = left;
    }
    foreach (c; 0 .. k)
    {
        if (normaliseColumnSign(res.U, c))
            foreach (i; 0 .. res.V.rows)
                res.V.data[i * k + c] = -res.V.data[i * k + c];
    }
    return res;
}

/// Singular values only (descending); cheaper than $(LREF svd) since no
/// vectors are accumulated.
double[] singularValues(const Matrix a)
{
    auto j = makeWorkingSet(a, false);
    sweep(j);
    auto sigma = new double[](j.cols);
    foreach (c; 0 .. j.cols)
        sigma[c] = columnNorm(j.wcol(c));
    auto order = descendingOrder(sigma);
    auto res = new double[](j.cols);
    foreach (c; 0 .. j.cols)
        res[c] = sigma[order[c]];
    return res;
}

/**
 * 2-norm condition number `σ_max / σ_min`.
 *
 * Throws: `singular` when the smallest singular value is exactly zero.
 */
double conditionNumber(const Matrix a)
{
    auto s = singularValues(a);
    enforceCode(s[$ - 1] != 0.0, ErrorCode.singular);
    return s[0] / s[$ - 1];
}
