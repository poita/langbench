/// Shared helpers for the unit tests.
module tests.helpers;

import std.math : abs;
import linalg;

/// Max absolute entrywise difference; infinity if shapes differ.
double maxDiff(const Matrix a, const Matrix b)
{
    if (a.rows != b.rows || a.cols != b.cols)
        return double.infinity;
    double d = 0;
    foreach (i; 0 .. a.data.length)
        d = abs(a.data[i] - b.data[i]) > d ? abs(a.data[i] - b.data[i]) : d;
    return d;
}

/// True when the two matrices agree to within `tol` everywhere.
bool close(const Matrix a, const Matrix b, double tol = 1e-12)
{
    return maxDiff(a, b) <= tol;
}

/// Assert that `dg` throws a `LinalgException` with the given code.
void assertCode(ErrorCode code, scope void delegate() dg, string file = __FILE__, size_t line = __LINE__)
{
    try
    {
        dg();
    }
    catch (LinalgException e)
    {
        if (e.code != code)
            throw new Error("wrong error code: " ~ e.msg, file, line);
        return;
    }
    throw new Error("expected a LinalgException", file, line);
}

/// A deterministic pseudo-random matrix with entries in [-1, 1).
Matrix pseudoRandom(size_t m, size_t n, uint seed = 12345)
{
    auto a = Matrix(m, n);
    ulong s = seed;
    foreach (ref x; a.data)
    {
        s = s * 6364136223846793005UL + 1442695040888963407UL;
        x = (cast(double)(s >> 11) / 9007199254740992.0) * 2.0 - 1.0;
    }
    return a;
}
