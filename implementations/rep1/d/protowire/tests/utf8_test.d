module utf8_test;

import protowire.utf8;

private bool valid(const(ubyte)[] s) @safe { return isValidUtf8(s); }

@safe unittest
{
    assert(valid([]));
    assert(valid(cast(const(ubyte)[]) "hello, world with more than eight ascii bytes"));
    assert(valid([0x00, 0x7f]));
    assert(valid([0xc3, 0xa9]));
    assert(valid([0xe2, 0x82, 0xac]));
    assert(valid([0xf0, 0x9f, 0x98, 0x80]));
    assert(valid([0xed, 0x9f, 0xbf]));    // U+D7FF
    assert(valid([0xf4, 0x8f, 0xbf, 0xbf])); // U+10FFFF
}

@safe unittest
{
    assert(!valid([0x80]));               // stray continuation
    assert(!valid([0xc0, 0x80]));         // overlong
    assert(!valid([0xc1, 0xbf]));
    assert(!valid([0xe0, 0x80, 0x80]));   // overlong
    assert(!valid([0xf0, 0x80, 0x80, 0x80]));
    assert(!valid([0xed, 0xa0, 0x80]));   // surrogate U+D800
    assert(!valid([0xf4, 0x90, 0x80, 0x80])); // > U+10FFFF
    assert(!valid([0xf5, 0x80, 0x80, 0x80]));
    assert(!valid([0xc3]));               // truncated
    assert(!valid([0xe2, 0x82]));
    assert(!valid([0xf0, 0x9f, 0x98]));
    assert(!valid(cast(const(ubyte)[]) "abcdefgh\xc3"));
}
