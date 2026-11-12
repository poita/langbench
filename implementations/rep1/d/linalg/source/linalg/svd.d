/**
 * Singular value decomposition by one-sided (Hestenes) Jacobi, and the
 * condition number derived from it.
 */
module linalg.svd;

import std.math : abs, sqrt;

import linalg.errors;
import linalg.matrix;
import linalg.ops : transpose;
import linalg.ordering;

/// Thin SVD `A = U diag(s) Vᵀ` with `k = min(m, n)`.
struct SVD
{
    /// `m x k`, orthonormal columns, sign-normalised.
    Matrix u;
    /// `k` singular values, descending, non-negative.
    double[] s;
    /// `n x k`, orthonormal columns.
    Matrix v;
}

/// Maximum number of Jacobi sweeps.
enum maxSweeps = 60;

/**
 * Thin SVD. Matrices with fewer rows than columns are decomposed through
 * their transpose. Each column of `U` is sign-normalised and the matching
 * column of `V` negated with it.
 */
SVD svd(const Matrix a) @safe pure
{
    const wide = a.rows < a.cols;
    const work = wide ? transpose(a) : a;
    const m = work.rows, n = work.cols;     // m >= n == k

    // W and V are stored as n columns of contiguous memory.
    auto w = new double[][n];
    auto v = new double[][n];
    foreach (j; 0 .. n)
    {
        w[j] = new double[m];
        foreach (i; 0 .. m)
            w[j][i] = work.data[i * n + j];
        v[j] = new double[n];
        v[j][] = 0.0;
        v[j][j] = 1.0;
    }

    foreach (sweep; 0 .. maxSweeps)
    {
        bool rotated = false;
        foreach (p; 0 .. n)
            foreach (q; p + 1 .. n)
            {
                auto wp = w[p], wq = w[q];
                double alpha = 0.0, beta = 0.0, gamma = 0.0;
                foreach (i; 0 .. m)
                {
                    alpha += wp[i] * wp[i];
                    beta += wq[i] * wq[i];
                    gamma += wp[i] * wq[i];
                }
                if (gamma == 0.0 || alpha == 0.0 || beta == 0.0
                        || abs(gamma) <= 1e-14 * sqrt(alpha * beta))
                    continue;
                rotated = true;
                const zeta = (beta - alpha) / (2.0 * gamma);
                const t = zeta >= 0.0
                    ? 1.0 / (zeta + sqrt(zeta * zeta + 1.0))
                    : -1.0 / (-zeta + sqrt(zeta * zeta + 1.0));
                const c = 1.0 / sqrt(t * t + 1.0);
                const s = t * c;
                foreach (i; 0 .. m)
                {
                    const x = wp[i], y = wq[i];
                    wp[i] = c * x - s * y;
                    wq[i] = s * x + c * y;
                }
                auto vp = v[p], vq = v[q];
                foreach (i; 0 .. n)
                {
                    const x = vp[i], y = vq[i];
                    vp[i] = c * x - s * y;
                    vq[i] = s * x + c * y;
                }
            }
        if (!rotated)
            break;
    }

    auto sigma = new double[n];
    foreach (j; 0 .. n)
    {
        double ss = 0.0;
        foreach (x; w[j])
            ss += x * x;
        sigma[j] = sqrt(ss);
    }
    const order = sortedOrder(sigma, true);

    // Left factor `lf` (m x n) and right factor `rf` (n x n) of the working matrix.
    auto lf = Matrix(m, n);
    auto rf = Matrix(n, n);
    SVD res;
    res.s = new double[n];
    foreach (j, src; order)
    {
        res.s[j] = sigma[src];
        foreach (i; 0 .. m)
            lf.data[i * n + j] = sigma[src] == 0.0 ? 0.0 : w[src][i] / sigma[src];
        foreach (i; 0 .. n)
            rf.data[i * n + j] = v[src][i];
    }

    // For a wide input the roles swap: U = right factor, V = left factor.
    if (wide)
    {
        res.u = rf;
        res.v = lf;
    }
    else
    {
        res.u = lf;
        res.v = rf;
    }
    auto col = new double[res.u.rows];
    foreach (j; 0 .. n)
    {
        foreach (i; 0 .. res.u.rows)
            col[i] = res.u.data[i * n + j];
        if (needsNegation(col))
        {
            foreach (i; 0 .. res.u.rows)
                res.u.data[i * n + j] = -res.u.data[i * n + j];
            foreach (i; 0 .. res.v.rows)
                res.v.data[i * n + j] = -res.v.data[i * n + j];
        }
    }
    return res;
}

/**
 * `σ_max / σ_min`. Throws `singular` when the smallest singular value is
 * exactly zero.
 */
double condition(const Matrix a) @safe pure
{
    const f = svd(a);
    const smallest = f.s[$ - 1];
    enforceCode(smallest != 0.0, ErrorCode.singular);
    return f.s[0] / smallest;
}

version (unittest)
{
    private void checkReconstruction(const Matrix a)
    {
        import linalg.ops : mul;

        const f = svd(a);
        const k = f.s.length;
        auto d = Matrix(k, k);
        foreach (i; 0 .. k)
            d[i, i] = f.s[i];
        const r = mul(mul(f.u, d), transpose(f.v));
        assert(r.rows == a.rows && r.cols == a.cols);
        foreach (i; 0 .. a.data.length)
            assert(abs(r.data[i] - a.data[i]) < 1e-12);
        foreach (i; 1 .. k)
            assert(f.s[i - 1] >= f.s[i]);
    }
}

unittest
{
    checkReconstruction(Matrix.fromRows([[1.0, 2.0], [3.0, 4.0], [5.0, 7.0]]));
    checkReconstruction(Matrix.fromRows([[1.0, 2.0, 3.0], [4.0, 5.0, 7.0]]));
    checkReconstruction(Matrix.fromRows([[2.0, 1.0], [1.0, 3.0]]));
}

unittest
{
    const a = Matrix.fromRows([[3.0, 0.0], [0.0, -2.0]]);
    const f = svd(a);
    assert(f.s == [3.0, 2.0]);
    assert(f.u == Matrix.fromRows([[1.0, 0.0], [0.0, 1.0]]));
    assert(f.v == Matrix.fromRows([[1.0, 0.0], [0.0, -1.0]]));   // sign moved to V
    assert(abs(condition(a) - 1.5) < 1e-15);
}

unittest
{
    import std.exception : collectException;

    assert(collectException!LinAlgException(condition(Matrix(2, 2))).code == ErrorCode.singular);
}
