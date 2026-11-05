/// Tests for number formatting and parsing.
module langvm.test_numfmt;

import langvm.numfmt;

unittest
{
    assert(formatFloatAt(1.0, 6) == "1.000000");
    assert(formatFloatAt(2.5, 0) == "2");
    assert(formatFloatAt(3.5, 0) == "4");
    assert(formatFloatAt(0.5, 0) == "0");
    assert(formatFloatAt(-0.0, 6) == "-0.000000");
    assert(formatFloatAt(0.1 + 0.2, 17) == "0.30000000000000004");
    assert(formatFloatAt(2.675, 2) == "2.67");
    assert(formatFloatAt(1e21, 2) == "1000000000000000000000.00");
    assert(formatFloatAt(double.nan, 3) == "nan");
    assert(formatFloatAt(-double.infinity, 3) == "-inf");
}

unittest
{
    assert(formatIntRadix(255, 16) == "ff");
    assert(formatIntRadix(-255, 2) == "-11111111");
    assert(formatIntRadix(long.min, 10) == "-9223372036854775808");
    long v;
    assert(parseIntRadix("-9223372036854775808"d, 10, v) && v == long.min);
    assert(!parseIntRadix("9223372036854775808"d, 10, v));
    assert(!parseIntRadix(""d, 10, v) && !parseIntRadix("-"d, 10, v));
    assert(parseIntRadix("Zz"d, 36, v) && v == 1295);
    assert(!parseIntRadix("8"d, 8, v));
    double d;
    assert(parseFloatText("12."d, d) && d == 12.0);
    assert(parseFloatText(".5e1"d, d) && d == 5.0);
    assert(!parseFloatText("."d, d) && !parseFloatText("1e"d, d) && !parseFloatText("1_0"d, d));
}
