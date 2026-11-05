module utf8_tests;

import canonjson.utf8;

private bool ok(const(ubyte)[] b) { return validateUtf8(b); }

unittest // valid sequences
{
    assert(ok([]));
    assert(ok(cast(const(ubyte)[]) "plain ascii, longer than eight bytes"));
    assert(ok([0xC3, 0xA9]));                 // é
    assert(ok([0xE2, 0x82, 0xAC]));           // €
    assert(ok([0xF0, 0x9F, 0x98, 0x80]));     // U+1F600
    assert(ok([0xED, 0x9F, 0xBF]));           // U+D7FF
    assert(ok([0xEE, 0x80, 0x80]));           // U+E000
    assert(ok([0xF4, 0x8F, 0xBF, 0xBF]));     // U+10FFFF
    assert(ok([0xEF, 0xBB, 0xBF]));           // BOM is valid UTF-8 (rejected elsewhere)
}

unittest // invalid sequences
{
    assert(!ok([0x80]));                      // lone continuation
    assert(!ok([0xC0, 0x80]));                // overlong NUL
    assert(!ok([0xC1, 0xBF]));                // overlong
    assert(!ok([0xE0, 0x80, 0x80]));          // overlong 3-byte
    assert(!ok([0xF0, 0x80, 0x80, 0x80]));    // overlong 4-byte
    assert(!ok([0xED, 0xA0, 0x80]));          // U+D800
    assert(!ok([0xED, 0xBF, 0xBF]));          // U+DFFF
    assert(!ok([0xF4, 0x90, 0x80, 0x80]));    // U+110000
    assert(!ok([0xF5, 0x80, 0x80, 0x80]));
    assert(!ok([0xFF]));
    assert(!ok([0xC3]));                      // truncated
    assert(!ok([0xE2, 0x82]));
    assert(!ok([0xF0, 0x9F, 0x98]));
    assert(!ok([0xC3, 0x28]));                // bad continuation
    assert(!ok([0xE2, 0x28, 0xA1]));
    assert(!ok([0xF0, 0x9F, 0x28, 0x80]));
}

unittest // error after a long ASCII run is still found
{
    ubyte[] b = new ubyte[100];
    b[] = 'a';
    assert(ok(b));
    b[93] = 0xFF;
    assert(!ok(b));
    b[93] = 'a';
    b[99] = 0xC3; // truncated at the very end
    assert(!ok(b));
}

unittest // BOM detection
{
    assert(hasByteOrderMark([0xEF, 0xBB, 0xBF, '1']));
    assert(!hasByteOrderMark([0xEF, 0xBB]));
    assert(!hasByteOrderMark(cast(const(ubyte)[]) "1"));
}

unittest // encoder
{
    import canonjson.buffer : ByteBuffer;
    ByteBuffer b;
    encodeUtf8(b, 0x41);
    encodeUtf8(b, 0xE9);
    encodeUtf8(b, 0x20AC);
    encodeUtf8(b, 0x1F600);
    assert(b.data == cast(const(ubyte)[]) "A\u00e9\u20ac\U0001F600");
}
