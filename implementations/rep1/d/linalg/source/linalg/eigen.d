/**
 * Symmetric eigendecomposition by the cyclic Jacobi method.
 */
module linalg.eigen;

import std.math : sqrt;

import linalg.errors;
import linalg.matrix;
import linalg.ops : isSymmetric, normFro;
import linalg.ordering;

/// Eigendecomposition `A = V diag(w) Vᵀ`.
struct Eigen
{
    /// Eigenvalues, ascending.
    double[] w;
    /// Orthogonal matrix whose column `j` is the unit eigenvector for `w[j]`,
    /// sign-normalised (see `linalg.ordering.needsNegation`).
    Matrix v;
}

/// Maximum number of Jacobi sweeps.
enum maxSweeps = 60;

private double offDiagonal(const double[] m, size_t n) @safe pure nothrow @nogc
{
    double s = 0.0;
    foreach (i; 0 .. n)
        foreach (j; i + 1 .. n)
            s += m[i * n + j] * m[i * n + j];
    return sqrt(2.0 * s);
}

/**
 * Cyclic Jacobi for a symmetric matrix. Sweeps run until the off-diagonal
 * norm drops to `1e-14 * ‖A‖F`, stops decreasing, or 60 sweeps have run.
 *
 * Throws: `notSquare`, `notSymmetric`.
 */
Eigen symmetricEigen(const Matrix a) @safe pure
{
    enforceCode(a.isSquare, ErrorCode.notSquare);
    enforceCode(isSymmetric(a), ErrorCode.notSymmetric);
    const n = a.rows;
    auto mm = a.dup;
    auto m = mm.data;
    // Row p of `vt` holds column p of V, so rotations touch contiguous memory.
    auto vtm = Matrix.identity(n);
    auto vt = vtm.data;
    const phi = normFro(a);
    double prev = double.infinity;

    foreach (sweep; 0 .. maxSweeps)
    {
        const off = offDiagonal(m, n);
        if (off <= 1e-14 * phi || off >= prev)
            break;
        prev = off;
        foreach (p; 0 .. n)
            foreach (q; p + 1 .. n)
            {
                const apq = m[p * n + q];
                if (apq == 0.0)
                    continue;
                const theta = (m[q * n + q] - m[p * n + p]) / (2.0 * apq);
                const t = theta >= 0.0
                    ? 1.0 / (theta + sqrt(theta * theta + 1.0))
                    : -1.0 / (-theta + sqrt(theta * theta + 1.0));
                const c = 1.0 / sqrt(t * t + 1.0);
                const s = t * c;

                foreach (i; 0 .. n)
                {
                    const x = m[i * n + p], y = m[i * n + q];
                    m[i * n + p] = c * x - s * y;
                    m[i * n + q] = s * x + c * y;
                }
                {
                    auto rp = m[p * n .. (p + 1) * n];
                    auto rq = m[q * n .. (q + 1) * n];
                    foreach (j; 0 .. n)
                    {
                        const x = rp[j], y = rq[j];
                        rp[j] = c * x - s * y;
                        rq[j] = s * x + c * y;
                    }
                }
                m[p * n + q] = 0.0;
                m[q * n + p] = 0.0;
                {
                    auto vp = vt[p * n .. (p + 1) * n];
                    auto vq = vt[q * n .. (q + 1) * n];
                    foreach (i; 0 .. n)
                    {
                        const x = vp[i], y = vq[i];
                        vp[i] = c * x - s * y;
                        vq[i] = s * x + c * y;
                    }
                }
            }
    }

    auto diag = new double[n];
    foreach (i; 0 .. n)
        diag[i] = m[i * n + i];
    const order = sortedOrder(diag);
    Eigen e;
    e.w = new double[n];
    e.v = Matrix(n, n);
    foreach (j, src; order)
    {
        e.w[j] = diag[src];
        const col = vt[src * n .. (src + 1) * n];
        const flip = needsNegation(col);
        foreach (i; 0 .. n)
            e.v.data[i * n + j] = flip ? -col[i] : col[i];
    }
    return e;
}

unittest
{
    import std.math : abs;

    auto a = Matrix.fromRows([[2.0, 1.0], [1.0, 3.0]]);
    const e = symmetricEigen(a);
    assert(abs(e.w[0] - (5.0 - sqrt(5.0)) / 2) < 1e-14);
    assert(abs(e.w[1] - (5.0 + sqrt(5.0)) / 2) < 1e-14);
    assert(abs(e.v[0, 0] - 0.8506508083520399) < 1e-14);
    assert(abs(e.v[1, 0] + 0.5257311121191336) < 1e-14);
    assert(abs(e.v[0, 1] - 0.5257311121191336) < 1e-14);
    assert(abs(e.v[1, 1] - 0.8506508083520399) < 1e-14);
}

unittest
{
    import linalg.ops : mul, transpose;
    import std.math : abs;

    auto a = Matrix.fromRows([[4.0, 1.0, 0.5], [1.0, 3.0, -1.0], [0.5, -1.0, 1.0]]);
    const e = symmetricEigen(a);
    assert(e.w[0] < e.w[1] && e.w[1] < e.w[2]);
    auto d = Matrix(3, 3);
    foreach (i; 0 .. 3)
        d[i, i] = e.w[i];
    const r = mul(mul(e.v, d), transpose(e.v));
    foreach (i; 0 .. 9)
        assert(abs(r.data[i] - a.data[i]) < 1e-13);
}

unittest
{
    import std.exception : collectException;

    assert(collectException!LinAlgException(symmetricEigen(Matrix(2, 3))).code
            == ErrorCode.notSquare);
    assert(collectException!LinAlgException(
            symmetricEigen(Matrix.fromRows([[1.0, 2.0], [0.0, 1.0]]))).code
            == ErrorCode.notSymmetric);
    // A diagonal matrix needs no rotation; eigenvalues come out sorted.
    const e = symmetricEigen(Matrix.fromRows([[3.0, 0.0], [0.0, 1.0]]));
    assert(e.w == [1.0, 3.0]);
}
