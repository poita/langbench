/**
 * Dense row-major matrix of `double`.
 */
module linalg.matrix;

/// A dense `rows x cols` matrix of doubles stored row-major.
struct Matrix
{
    /// Number of rows.
    size_t rows;
    /// Number of columns.
    size_t cols;
    /// Entries, row-major: entry `(i, j)` is `data[i * cols + j]`.
    double[] data;

    /// A `rows x cols` matrix of zeros.
    this(size_t rows, size_t cols) @safe pure nothrow
    {
        this.rows = rows;
        this.cols = cols;
        this.data = new double[rows * cols];
        this.data[] = 0.0;
    }

    /// Wraps existing row-major storage (no copy).
    this(size_t rows, size_t cols, double[] data) @safe pure nothrow
    in (data.length == rows * cols)
    {
        this.rows = rows;
        this.cols = cols;
        this.data = data;
    }

    /// Builds a matrix from an array of equally long rows.
    static Matrix fromRows(const double[][] r) @safe pure
    {
        const n = r.length;
        const m = n == 0 ? 0 : r[0].length;
        auto result = Matrix(n, m);
        foreach (i, row; r)
        {
            assert(row.length == m, "rows must have equal length");
            result.data[i * m .. (i + 1) * m] = row[];
        }
        return result;
    }

    /// The `n x n` identity.
    static Matrix identity(size_t n) @safe pure nothrow
    {
        auto result = Matrix(n, n);
        foreach (i; 0 .. n)
            result.data[i * n + i] = 1.0;
        return result;
    }

    /// Entry `(i, j)`.
    ref inout(double) opIndex(size_t i, size_t j) inout @safe pure nothrow @nogc
    in (i < rows && j < cols)
    {
        return data[i * cols + j];
    }

    /// Row `i` as a slice of the underlying storage.
    inout(double)[] row(size_t i) inout @safe pure nothrow @nogc
    in (i < rows)
    {
        return data[i * cols .. (i + 1) * cols];
    }

    /// True when the matrix is square.
    bool isSquare() const @safe pure nothrow @nogc
    {
        return rows == cols;
    }

    /// A copy that shares no storage with the original.
    Matrix dup() const @safe pure nothrow
    {
        return Matrix(rows, cols, data.dup);
    }

    /// Exact equality of shape and entries.
    bool opEquals(const Matrix other) const @safe pure nothrow @nogc
    {
        return rows == other.rows && cols == other.cols && data == other.data;
    }
}

unittest
{
    auto m = Matrix.fromRows([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]);
    assert(m.rows == 2 && m.cols == 3);
    assert(m[1, 2] == 6.0);
    m[0, 1] = -2.0;
    assert(m.row(0) == [1.0, -2.0, 3.0]);
    assert(!m.isSquare);
}

unittest
{
    auto i = Matrix.identity(3);
    assert(i[0, 0] == 1.0 && i[0, 1] == 0.0 && i[2, 2] == 1.0);
    auto c = i.dup;
    c[0, 0] = 5.0;
    assert(i[0, 0] == 1.0 && c != i);
}
