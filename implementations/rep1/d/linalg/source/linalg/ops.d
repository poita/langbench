/**
 * Elementwise operations, products, transpose and matrix norms.
 *
 * Every sum is a single running sum in the order documented on the function,
 * so results are reproducible bit for bit.
 */
module linalg.ops;

import std.math : abs, fmax, sqrt;

import linalg.errors;
import linalg.matrix;

/// `A + B`. Throws `dimensionMismatch` when the shapes differ.
Matrix add(const Matrix a, const Matrix b) @safe pure
{
    enforceCode(a.rows == b.rows && a.cols == b.cols, ErrorCode.dimensionMismatch);
    auto c = Matrix(a.rows, a.cols);
    foreach (i; 0 .. a.data.length)
        c.data[i] = a.data[i] + b.data[i];
    return c;
}

/**
 * `A B` for `m x k` and `k x n`; each entry is one running sum over
 * increasing `k`. Throws `dimensionMismatch` when `A.cols != B.rows`.
 */
Matrix mul(const Matrix a, const Matrix b) @safe pure
{
    enforceCode(a.cols == b.rows, ErrorCode.dimensionMismatch);
    const m = a.rows, kk = a.cols, n = b.cols;
    auto c = Matrix(m, n);
    foreach (i; 0 .. m)
    {
        auto ci = c.data[i * n .. (i + 1) * n];
        foreach (k; 0 .. kk)
        {
            const aik = a.data[i * kk + k];
            const bk = b.data[k * n .. (k + 1) * n];
            foreach (j; 0 .. n)
                ci[j] += aik * bk[j];
        }
    }
    return c;
}

/// The transpose `Aᵀ`.
Matrix transpose(const Matrix a) @safe pure nothrow
{
    auto t = Matrix(a.cols, a.rows);
    foreach (i; 0 .. a.rows)
        foreach (j; 0 .. a.cols)
            t.data[j * a.rows + i] = a.data[i * a.cols + j];
    return t;
}

/// True when `A[i][j] == A[j][i]` exactly for every pair (square matrices).
bool isSymmetric(const Matrix a) @safe pure nothrow @nogc
{
    if (!a.isSquare)
        return false;
    foreach (i; 0 .. a.rows)
        foreach (j; 0 .. i)
            if (a.data[i * a.cols + j] != a.data[j * a.cols + i])
                return false;
    return true;
}

/// Maximum absolute column sum, each column summed over increasing row.
double norm1(const Matrix a) @safe pure nothrow
{
    auto sums = new double[a.cols];
    sums[] = 0.0;
    foreach (i; 0 .. a.rows)
        foreach (j; 0 .. a.cols)
            sums[j] += abs(a.data[i * a.cols + j]);
    double best = 0.0;
    foreach (s; sums)
        best = fmax(best, s);
    return best;
}

/// Maximum absolute row sum, each row summed over increasing column.
double normInf(const Matrix a) @safe pure nothrow
{
    double best = 0.0;
    foreach (i; 0 .. a.rows)
    {
        double s = 0.0;
        foreach (x; a.data[i * a.cols .. (i + 1) * a.cols])
            s += abs(x);
        best = fmax(best, s);
    }
    return best;
}

/// Frobenius norm; squares summed row by row, each row over increasing column.
double normFro(const Matrix a) @safe pure nothrow
{
    double s = 0.0;
    foreach (x; a.data)
        s += x * x;
    return sqrt(s);
}

unittest
{
    auto a = Matrix.fromRows([[1.0, 2.0], [3.0, 4.0]]);
    auto b = Matrix.fromRows([[0.5, 0.0], [0.0, -1.5]]);
    assert(add(a, b) == Matrix.fromRows([[1.5, 2.0], [3.0, 2.5]]));
    assert(mul(a, a) == Matrix.fromRows([[7.0, 10.0], [15.0, 22.0]]));
    assert(transpose(a) == Matrix.fromRows([[1.0, 3.0], [2.0, 4.0]]));
}

unittest
{
    import std.exception : collectException;

    auto a = Matrix(2, 3);
    auto b = Matrix(2, 3);
    assert(collectException!LinAlgException(mul(a, b)).code == ErrorCode.dimensionMismatch);
    assert(collectException!LinAlgException(add(a, Matrix(3, 2))).code
            == ErrorCode.dimensionMismatch);
    assert(transpose(a).rows == 3);
}

unittest
{
    auto a = Matrix.fromRows([[1.0, -2.0], [-3.0, 4.0]]);
    assert(norm1(a) == 6.0);
    assert(normInf(a) == 7.0);
    assert(normFro(a) == sqrt(30.0));
    assert(!isSymmetric(a));
    assert(isSymmetric(Matrix.fromRows([[1.0, 2.0], [2.0, 5.0]])));
    assert(!isSymmetric(Matrix(2, 3)));
}
