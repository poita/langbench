module tests.mmio_test;

import std.algorithm : canFind, startsWith, count;
import linalg;
import tests.helpers;

private Matrix parse(string s)
{
    return parseMatrixMarket(s);
}

unittest // array general is column-major
{
    auto m = parse("%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n");
    assert(m.data == [1.0, 2, 3, 4]);
}

unittest // array symmetric and skew-symmetric
{
    auto s = parse("%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n");
    assert(s.data == [4.0, 2, 2, 5]);
    auto k = parse("%%MatrixMarket matrix array real skew-symmetric\n3 3\n1\n2\n3\n");
    assert(k.data == [0.0, -1, -2, 1, 0, -3, 2, 3, 0]);
}

unittest // coordinate general, with comments and blank lines
{
    auto m = parse("%%MatrixMarket matrix coordinate real general\n% a comment\n\n"
        ~ "  \n2 3 2\n\n1 1 0.5\n2 3 -1.5E+00\n");
    assert(m.rows == 2 && m.cols == 3);
    assert(m.data == [0.5, 0, 0, 0, 0, -1.5]);
}

unittest // coordinate symmetric / skew / pattern / integer
{
    auto s = parse("%%MatrixMarket matrix coordinate real symmetric\n3 3 3\n1 1 2\n2 1 7\n3 3 1\n");
    assert(s.data == [2.0, 7, 0, 7, 0, 0, 0, 0, 1]);
    auto k = parse("%%MatrixMarket matrix coordinate real skew-symmetric\n3 3 1\n3 1 5\n");
    assert(k[2, 0] == 5 && k[0, 2] == -5);
    auto p = parse("%%MatrixMarket matrix coordinate pattern symmetric\n2 2 2\n1 1\n2 1\n");
    assert(p.data == [1.0, 1, 1, 0]);
    auto i = parse("%%MatrixMarket MATRIX Coordinate INTEGER General\n1 2 2\n1 1 3\n1 2 -4\n");
    assert(i.data == [3.0, -4]);
}

unittest // values parse to the correctly rounded double
{
    auto m = parse("%%MatrixMarket matrix array real general\n1 3\n0.1\n3.0e-7\n1.0E+03\n");
    assert(m.data[0] == 0.1 && m.data[1] == 3.0e-7 && m.data[2] == 1000.0);
}

unittest // malformed input is rejected
{
    bool threw;
    try parse("not a matrix\n1 1\n1.0\n");
    catch (MatrixMarketException) threw = true;
    assert(threw);
}

unittest // output format
{
    auto m = Matrix.fromRows([[1.5, -0.0], [0.0, 40015.422479]]);
    auto text = formatMatrixMarket(m).idup;
    assert(text == "%%MatrixMarket matrix array real general\n2 2\n"
        ~ "1.5000000000e+00\n0.0000000000e+00\n0.0000000000e+00\n4.0015422479e+04\n");
    assert(!text.canFind("-0.0"));
    auto big = Matrix(1, 2, [-7.0e-3, 1.0e100]);
    assert(formatMatrixMarket(big).idup ==
        "%%MatrixMarket matrix array real general\n1 2\n-7.0000000000e-03\n1.0000000000e+100\n");
}

unittest // write then read round trips to 11 significant digits
{
    auto a = pseudoRandom(5, 4);
    auto b = parseMatrixMarket(formatMatrixMarket(a));
    assert(close(a, b, 1e-10));
}
