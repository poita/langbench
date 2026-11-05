/// Tests for commonmark.buffer and commonmark.chars.
module commonmark_tests.buffer_test;

import commonmark.buffer;
import commonmark.chars;

unittest
{
    Buffer b;
    assert(b.empty);
    b.put("ab");
    b.put('c');
    b.putDecimal(120);
    assert(b.data == "abc120");
    assert(b.back == '0');
    assert(b.length == 6);
    b.clear();
    assert(b.empty);
    foreach (i; 0 .. 1000)
        b.put("xyz");
    assert(b.length == 3000);
}

unittest
{
    assert(isAsciiPunct('!') && isAsciiPunct('~') && !isAsciiPunct('a') && !isAsciiPunct(' '));
    assert(isWhitespace('\n') && isWhitespace('\t') && !isWhitespace('x'));
    assert(hexValue('F') == 15 && hexValue('a') == 10 && hexValue('7') == 7);
    assert(isAlnum('z') && isAlnum('0') && !isAlnum('-'));
}
