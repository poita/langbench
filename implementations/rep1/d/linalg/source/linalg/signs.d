/**
 * Sign convention for eigenvectors and singular vectors.
 */
module linalg.signs;

import linalg.matrix;

/**
 * Index of the first entry of `v` with the largest magnitude.
 * Returns 0 for an empty slice.
 */
size_t argMaxAbs(const(double)[] v) pure nothrow @nogc
{
    size_t best = 0;
    double bv = -1.0;
    foreach (i, x; v)
    {
        immutable a = x < 0 ? -x : x;
        if (a > bv)
        {
            bv = a;
            best = i;
        }
    }
    return best;
}

/**
 * Sign-normalise a vector in place: if its largest-magnitude entry (smallest
 * index on ties) is negative, negate the whole vector. An all-zero vector is
 * left alone.
 *
 * Returns: true if the vector was negated.
 */
bool normaliseSign(double[] v) pure nothrow @nogc
{
    if (v.length == 0)
        return false;
    if (v[argMaxAbs(v)] < 0.0)
    {
        foreach (ref x; v)
            x = -x;
        return true;
    }
    return false;
}

/**
 * Sign-normalise column `j` of `m` in place (see $(LREF normaliseSign)).
 *
 * Returns: true if the column was negated.
 */
bool normaliseColumnSign(ref Matrix m, size_t j) pure nothrow
{
    auto col = new double[](m.rows);
    foreach (i; 0 .. m.rows)
        col[i] = m.data[i * m.cols + j];
    if (!normaliseSign(col))
        return false;
    foreach (i; 0 .. m.rows)
        m.data[i * m.cols + j] = col[i];
    return true;
}
