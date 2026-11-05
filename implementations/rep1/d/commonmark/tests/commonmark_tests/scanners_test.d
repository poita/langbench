/// Tests for commonmark.scanners.
module commonmark_tests.scanners_test;

import commonmark.scanners;

unittest
{
    bool email;
    assert(scanAutolink("http://a.b/?x=1>", 0, email) == 15 && !email);
    assert(scanAutolink("foo@bar.example.com>", 0, email) == 19 && email);
    assert(scanAutolink("a:b>", 0, email) == -1); // scheme too short
    assert(scanAutolink("foo bar>", 0, email) == -1);
    assert(scanAutolink("foo@bar.>", 0, email) == -1);
    assert(scanAutolink("foo@-bar.com>", 0, email) == -1);
    assert(scanAutolink("made-up-scheme://foo,bar>", 0, email) == 24 && !email);
}

unittest
{
    LinkTail t;
    assert(scanLinkTail("/url \"title\")", 0, t));
    assert(t.hasTitle && t.destStart == 0 && t.destEnd == 4 && t.end == 13);
    assert(t.titleStart == 6 && t.titleEnd == 11);
    assert(!scanLinkTail("/my uri)", 0, t));
    assert(scanLinkTail("<>)", 0, t) && t.destStart == t.destEnd);
    assert(scanLinkTail("a(b(c))d)", 0, t) && t.destEnd == 8);
    assert(!scanLinkTail("a(b", 0, t));
    assert(!scanLinkTail("<a\nb>)", 0, t));
    assert(scanLinkTail("  /u  'x'  )", 0, t) && t.hasTitle);
    // Without a space the quoted text is part of the destination.
    assert(scanLinkTail("/u\"t\")", 0, t) && !t.hasTitle && t.destEnd == 5);
}

unittest
{
    assert(scanTitle(`"a\"b"`, 0) == 6);
    assert(scanTitle(`"abc`, 0) == -1);
    assert(scanTitle(`(a\)b)`, 0) == 6);
    assert(scanTitle(`(a(b)`, 0) == -1);
    assert(scanTitle(`'it''s'`, 0) == 4);
}
