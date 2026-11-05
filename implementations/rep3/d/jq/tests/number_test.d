module tests.number_test;

import jq.buffer;
import jq.number;

private string fmt(double d)
{
    Buf b;
    putNumber(b, d);
    return b.slice.idup;
}

unittest
{
    assert(fmt(0) == "0");
    assert(fmt(-12) == "-12");
    assert(fmt(1e12) == "1000000000000");
    assert(fmt(9007199254740991.0) == "9007199254740991");
    assert(fmt(1.5) == "1.5");
    assert(fmt(0.125) == "0.125");
    assert(fmt(-0.001) == "-0.001");
    assert(fmt(3086419725308.5) == "3086419725308.5");
    assert(fmt(0.1 + 0.2) == "0.30000000000000004");
}

unittest
{
    assert(isJsonNumber("0") && isJsonNumber("-1.5e+3") && isJsonNumber("12"));
    assert(!isJsonNumber("") && !isJsonNumber("-") && !isJsonNumber("01")
            && !isJsonNumber("1.") && !isJsonNumber(".5") && !isJsonNumber("1e")
            && !isJsonNumber(" 1") && !isJsonNumber("abc"));
    double d;
    assert(tryParseNumber("3.25", d) && d == 3.25);
    assert(!tryParseNumber("12abc", d));
    assert(parseNumber("123456789.123456789") == 123456789.123456789);
    assert(parseNumber("0.3") == 0.3);
}
