module keyorder_tests;

import canonjson.keyorder;

private int cmp(string a, string b)
{
    return compareKeys(cast(const(ubyte)[]) a, cast(const(ubyte)[]) b);
}

unittest // basic ordering
{
    assert(cmp("", "") == 0);
    assert(cmp("a", "a") == 0);
    assert(cmp("", "a") < 0);
    assert(cmp("a", "") > 0);
    assert(cmp("a", "b") < 0);
    assert(cmp("ab", "a") > 0);   // proper prefix sorts first
    assert(cmp("Z", "a") < 0);
}

unittest // the example chain from the specification
{
    immutable string[] chain = [
        "", "Z", "a", "a\u0000", "aa", "\u00e9", "\U0001F600", "\uE000", "\uFFFF",
    ];
    foreach (i; 0 .. chain.length)
        foreach (j; 0 .. chain.length)
        {
            immutable c = cmp(chain[i], chain[j]);
            assert(i < j ? c < 0 : i == j ? c == 0 : c > 0);
        }
}

unittest // supplementary characters sort before U+E000..U+FFFF, unlike UTF-8 byte order
{
    assert(cmp("\U00010000", "\uFFFF") < 0);
    assert(cmp("\U0010FFFF", "\uE000") < 0);
    assert(cmp("\uD7FF", "\U00010000") < 0);   // BMP below the surrogates stays below
    assert(cmp("\uE000", "\uFFFF") < 0);
}

unittest // long shared prefixes (exercises the 8-byte skip) and multi-byte differences
{
    immutable p = "user:0000000000000000";
    assert(cmp(p ~ "1", p ~ "2") < 0);
    assert(cmp(p ~ "\U0001F600", p ~ "\uFFFF") < 0);
    assert(cmp(p ~ "\u00e9", p ~ "\u00ea") < 0);   // same lead byte, differing continuation
    assert(cmp(p ~ "\u00e9x", p ~ "\u00e9") > 0);
}
