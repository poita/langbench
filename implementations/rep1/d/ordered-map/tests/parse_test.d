/// Unit tests for orderedmap.parse and orderedmap.outbuf.
module parse_test;

import orderedmap.parse;
import orderedmap.outbuf;

unittest // parseLong
{
    size_t p = 0;
    assert(parseLong("0 x", p) == 0 && p == 1);
    p = 0;
    assert(parseLong("-17", p) == -17 && p == 3);
    p = 0;
    assert(parseLong("9223372036854775807", p) == long.max);
    p = 0;
    assert(parseLong("-9223372036854775808", p) == long.min);
}

unittest // parseULong stops at the first non-digit
{
    size_t p = 0;
    assert(parseULong("1000000000\n", p) == 1_000_000_000 && p == 10);
}

unittest // formatLong
{
    char[20] s;
    assert(formatLong(0, s) == "0");
    assert(formatLong(-1, s) == "-1");
    assert(formatLong(long.max, s) == "9223372036854775807");
    assert(formatLong(long.min, s) == "-9223372036854775808");
}

unittest // OutBuffer growth and contents
{
    OutBuffer b;
    b.put("ab");
    b.put('c');
    b.put(-12L);
    assert(b.data == "abc-12");
    foreach (i; 0 .. 10_000)
        b.put("0123456789");
    assert(b.length == 6 + 100_000);
    b.clear();
    assert(b.length == 0);
}
