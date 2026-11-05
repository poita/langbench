/// Tests for commonmark.entities.
module commonmark_tests.entities_test;

import commonmark.buffer;
import commonmark.entities;

unittest
{
    dchar cp;
    assert(matchEntity("&amp;", 0, cp) == 5 && cp == '&');
    assert(matchEntity("&lt;", 0, cp) == 4 && cp == '<');
    assert(matchEntity("&gt;", 0, cp) == 4 && cp == '>');
    assert(matchEntity("&quot;", 0, cp) == 6 && cp == '"');
    assert(matchEntity("&#65;", 0, cp) == 5 && cp == 'A');
    assert(matchEntity("&#x42;", 0, cp) == 6 && cp == 'B');
    assert(matchEntity("&#X42;", 0, cp) == 6 && cp == 'B');
    assert(matchEntity("&#0;", 0, cp) == 4 && cp == 0xFFFD);
    assert(matchEntity("&#xD800;", 0, cp) == 8 && cp == 0xFFFD);
    assert(matchEntity("&#x110000;", 0, cp) == 10 && cp == 0xFFFD);
    assert(matchEntity("&#12345678;", 0, cp) == 0);
    assert(matchEntity("&#;", 0, cp) == 0);
    assert(matchEntity("&#x;", 0, cp) == 0);
    assert(matchEntity("&copy;", 0, cp) == 0);
    assert(matchEntity("&amp", 0, cp) == 0);
    assert(matchEntity("&AMP;", 0, cp) == 0);
}

unittest
{
    Buffer b;
    putUtf8(b, 'A');
    putUtf8(b, 0xE9);
    putUtf8(b, 0x20AC);
    putUtf8(b, 0x1F600);
    assert(b.data == "Aé€\U0001F600");
}

unittest
{
    Buffer d, t;
    cleanText(`\&amp; &#92;* a\b`, d, t);
    assert(d.data == `& * a\b`);

    Buffer u;
    unescapeBackslashes(`\*a\\b\q`, u);
    assert(u.data == `*a\b\q`);

    Buffer e;
    decodeEntities("a &lt; b &foo; &#65", e);
    assert(e.data == "a < b &foo; &#65");
}
