/**
 * Dense real matrix type and the elementary operations on it.
 *
 * A $(LREF Matrix) owns one flat, contiguous, row-major `double` buffer.
 * All operations here are plain textbook algorithms whose floating-point
 * evaluation order is fixed and documented, so results are reproducible.
 */
module linalg.matrix;

import std.math : sqrt;
import linalg.errors;

/// A dense `rows x cols` matrix of doubles stored row-major in one buffer.
struct Matrix
{
    /// Number of rows.
    size_t rows;
    /// Number of columns.
    size_t cols;
    /// Row-major storage, `rows * cols` elements.
    double[] data;

    /// A zero-filled `rows x cols` matrix.
    this(size_t rows, size_t cols) pure nothrow
    {
        this.rows = rows;
        this.cols = cols;
        data = new double[](rows * cols);
        data[] = 0.0;
    }

    /// A matrix adopting `data` (row-major, length must be `rows * cols`).
    this(size_t rows, size_t cols, double[] data) pure nothrow @nogc
    in (data.length == rows * cols)
    {
        this.rows = rows;
        this.cols = cols;
        this.data = data;
    }

    /// Build a matrix from an array of equally long rows.
    static Matrix fromRows(double[][] rs) pure nothrow
    {
        immutable r = rs.length;
        immutable c = r ? rs[0].length : 0;
        auto m = Matrix(r, c);
        foreach (i; 0 .. r)
            m.row(i)[] = rs[i][];
        return m;
    }

    /// The `n x n` identity matrix.
    static Matrix identity(size_t n) pure nothrow
    {
        auto m = Matrix(n, n);
        foreach (i; 0 .. n)
            m.data[i * n + i] = 1.0;
        return m;
    }

    /// Row `i` as a slice into the storage.
    inout(double)[] row(size_t i) inout pure nothrow @nogc
    {
        return data[i * cols .. (i + 1) * cols];
    }

    /// Element `(i, j)`.
    double opIndex(size_t i, size_t j) const pure nothrow @nogc
    {
        return data[i * cols + j];
    }

    /// Assign element `(i, j)`.
    void opIndexAssign(double v, size_t i, size_t j) pure nothrow @nogc
    {
        data[i * cols + j] = v;
    }

    /// An independent copy.
    Matrix dup() const pure nothrow
    {
        return Matrix(rows, cols, data.dup);
    }

    /// True when `rows == cols`.
    bool isSquare() const pure nothrow @nogc
    {
        return rows == cols;
    }

    /// True when square and `A[i][j] == A[j][i]` exactly for all `i, j`.
    bool isSymmetric() const pure nothrow @nogc
    {
        if (rows != cols)
            return false;
        foreach (i; 0 .. rows)
            foreach (j; i + 1 .. cols)
                if (data[i * cols + j] != data[j * cols + i])
                    return false;
        return true;
    }
}

/// `y[j] += a * x[j]` for all `j`; `x` and `y` must not overlap.
package void axpy(double a, const(double)[] x, double[] y) pure nothrow @nogc
{
    assert(x.length == y.length);
    foreach (j; 0 .. y.length)
        y[j] += a * x[j];
}

/// `y[j] -= a * x[j]` for all `j`; `x` and `y` must not overlap.
package void subScaled(double a, const(double)[] x, double[] y) pure nothrow @nogc
{
    assert(x.length == y.length);
    foreach (j; 0 .. y.length)
        y[j] -= a * x[j];
}

/// Elementwise sum. Throws `dimension_mismatch` if the shapes differ.
Matrix add(const Matrix a, const Matrix b) pure
{
    enforceCode(a.rows == b.rows && a.cols == b.cols, ErrorCode.dimension_mismatch);
    auto c = Matrix(a.rows, a.cols);
    foreach (i; 0 .. c.data.length)
        c.data[i] = a.data[i] + b.data[i];
    return c;
}

/**
 * Matrix product `A B`. Every entry is one running sum over increasing `k`
 * (computed in row-axpy order, which has the same per-entry summation order
 * as the dot-product form). Throws `dimension_mismatch` unless
 * `a.cols == b.rows`.
 */
Matrix multiply(const Matrix a, const Matrix b) pure
{
    enforceCode(a.cols == b.rows, ErrorCode.dimension_mismatch);
    auto c = Matrix(a.rows, b.cols);
    foreach (i; 0 .. a.rows)
    {
        auto ci = c.row(i);
        auto ai = a.row(i);
        foreach (k; 0 .. a.cols)
        {
            immutable aik = ai[k];
            if (aik != 0.0)
                axpy(aik, b.row(k), ci);
        }
    }
    return c;
}

/// The transpose `Aᵀ`.
Matrix transpose(const Matrix a) pure nothrow
{
    auto t = Matrix(a.cols, a.rows);
    foreach (i; 0 .. a.rows)
    {
        auto ai = a.row(i);
        foreach (j; 0 .. a.cols)
            t.data[j * a.rows + i] = ai[j];
    }
    return t;
}

/// Maximum absolute column sum, each column summed over increasing row index.
double norm1(const Matrix a) pure nothrow
{
    auto sums = new double[](a.cols);
    sums[] = 0.0;
    foreach (i; 0 .. a.rows)
    {
        auto ai = a.row(i);
        foreach (j; 0 .. a.cols)
            sums[j] += ai[j] < 0 ? -ai[j] : ai[j];
    }
    double best = 0.0;
    foreach (s; sums)
        if (s > best)
            best = s;
    return best;
}

/// Maximum absolute row sum, each row summed over increasing column index.
double normInf(const Matrix a) pure nothrow
{
    double best = 0.0;
    foreach (i; 0 .. a.rows)
    {
        double s = 0.0;
        foreach (x; a.row(i))
            s += x < 0 ? -x : x;
        if (s > best)
            best = s;
    }
    return best;
}

/// Frobenius norm: each row's squares summed left to right, the row sums
/// added in row order, then square-rooted.
double normFro(const Matrix a) pure nothrow
{
    double total = 0.0;
    foreach (i; 0 .. a.rows)
    {
        double s = 0.0;
        foreach (x; a.row(i))
            s += x * x;
        total += s;
    }
    return sqrt(total);
}
